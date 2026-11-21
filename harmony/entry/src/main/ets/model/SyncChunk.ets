import { Logger } from './Logger';

/**
 * 全量快照的分片传输（PIT-056 / PIT-059）
 *
 * 为什么要分片：历史 / 回收站最多各 5000 条，整份 JSON 可能几百 KB，而公共事件的
 * 参数走 IPC、有大小上限 —— 超限时整条事件失败（或参数被截断），同步直接坏掉且没人发现。
 *
 * 两级切分：
 *  ① **条目级**：一条条目的 JSON 超过 `SLICE_CHARS` 就把它切成多段（`fid/part/parts`），
 *     接收方按 `fid` 把段拼回完整 JSON 再反序列化。这样"单条超长文本"也不会撑爆一片，
 *     且不需要压缩（本机 IPC 不缺带宽，缺的是单次事务大小；zlib 又只有文件级 API，
 *     还得落盘 + Base64，收益远小于复杂度）。
 *  ② **分片级**：把上面的「段」按 **条数 200 / 体积 64KB** 打包成若干事件。
 */

/** 快照类型 */
export const SNAP_HIST: string = 'hist';
export const SNAP_RECYCLE: string = 'recycle';

/** 每条事件最多多少段 */
export const CHUNK_ITEMS: number = 200;
/** 每条事件序列化后的体积上限（字符数，约等于字节数） */
export const CHUNK_BYTES: number = 64 * 1024;
/** 单条目 JSON 超过多少字符就切片 */
export const SLICE_CHARS: number = 48 * 1024;

/** 一个「条目片段」：同一条目的多段用 (fid) 归组、(part) 排序 */
export interface ChunkPiece {
  /** 条目组号（同一轮快照内唯一） */
  fid: number;
  /** 第几段 / 共几段 */
  part: number;
  parts: number;
  /** 该条目 JSON 的一段；多段拼起来才是完整 JSON */
  json: string;
}

export interface ChunkPayload {
  /** 快照类型：hist / recycle */
  kind: string;
  /** 本轮全量同步的编号（发起方生成；收方用它区分新旧两轮、丢弃残片） */
  sid: number;
  /** 分片序号，0 起 */
  seq: number;
  /** 分片总数 */
  total: number;
  /** 本片承载的条目片段 */
  items: ChunkPiece[];
}

export class SyncChunk {
  /**
   * 把一批条目打包成若干片（空列表也产出一片 total=1，语义 = "全量就是空的"）。
   * 大条目在这里被切成多段，接收方拼回。
   */
  static pack(kind: string, sid: number, objects: Object[]): ChunkPayload[] {
    const pieces: ChunkPiece[] = [];
    for (let i = 0; i < objects.length; i++) {
      let json: string = '';
      try {
        json = JSON.stringify(objects[i]);
      } catch (err) {
        json = '';
      }
      if (json === undefined || json === null || json === '') {
        continue;
      }
      if (json.length <= SLICE_CHARS) {
        pieces.push({ fid: i, part: 0, parts: 1, json: json });
        continue;
      }
      const parts: number = Math.ceil(json.length / SLICE_CHARS);
      for (let p = 0; p < parts; p++) {
        const from: number = p * SLICE_CHARS;
        pieces.push({
          fid: i,
          part: p,
          parts: parts,
          json: json.substring(from, Math.min(from + SLICE_CHARS, json.length))
        });
      }
      Logger.d(`SyncChunk.pack: 条目 #${i} 超长（${json.length} 字符）⇒ 切成 ${parts} 段`);
    }

    const groups: ChunkPiece[][] = [];
    let cur: ChunkPiece[] = [];
    let bytes: number = 0;
    for (let i = 0; i < pieces.length; i++) {
      const piece: ChunkPiece = pieces[i];
      let len: number = 0;
      try {
        // 用序列化后的长度估算实际载荷（转义、引号都算进去）
        len = JSON.stringify(piece).length;
      } catch (err) {
        len = SLICE_CHARS;
      }
      if (cur.length > 0 && (cur.length >= CHUNK_ITEMS || bytes + len > CHUNK_BYTES)) {
        groups.push(cur);
        cur = [];
        bytes = 0;
      }
      cur.push(piece);
      bytes += len;
    }
    if (cur.length > 0 || groups.length === 0) {
      groups.push(cur);
    }

    const out: ChunkPayload[] = [];
    for (let i = 0; i < groups.length; i++) {
      out.push({ kind: kind, sid: sid, seq: i, total: groups.length, items: groups[i] });
    }
    return out;
  }

  /** 解析分片；老格式（裸条目数组，无 kind）返回 undefined ⇒ 调用方按「单片全量」兼容处理 */
  static parse(json: string): ChunkPayload | undefined {
    if (json === undefined || json === null || json === '') {
      return undefined;
    }
    try {
      const p: ChunkPayload = JSON.parse(json) as ChunkPayload;
      if (p === undefined || p === null || typeof p.kind !== 'string') {
        return undefined;
      }
      if (typeof p.total !== 'number' || p.total <= 0 || typeof p.seq !== 'number') {
        return undefined;
      }
      return p;
    } catch (err) {
      return undefined;
    }
  }
}

/** 收方拼片器（App 侧：历史 / 回收站各持一个实例） */
export class ChunkAssembler {
  private kind: string = '';
  private sid: number = -1;
  private total: number = 0;
  /** 当前轮已收到的片（seq → payload）。CommonEvent 不保证到达顺序，必须乱序可收 */
  private got: Map<number, ChunkPayload> = new Map();
  /** seq0 还没到时先暂存的「预收片」（sid → seq → payload），等 seq0 到了对号入座 */
  private early: Map<number, Map<number, ChunkPayload>> = new Map();

  /**
   * 收一片；返回 true = 本轮已收齐（随后用 take() 取条目）。
   *
   * ⚠️ 为什么不能按 seq 严格顺序收（2026-11-21 事故）：
   * 键盘回 3 片 recycleSnapshot 时大包（62~65KB）后到、小包（7KB）先到，
   * 按 `seq === 上一片+1` 校验会把先到的尾片全部丢弃，seq0 到位后又因 seq1/seq2
   * 已被丢弃而永远拼不齐 ⇒ App 收不到回收站全量，误判「键盘没回应」去唤醒键盘。
   */
  push(p: ChunkPayload): boolean {
    if (p.seq === 0) {
      // 新一轮全量开始：丢掉上一轮残留，收编 seq0 之前乱序先到的同 sid 片
      if (p.kind !== this.kind || p.sid !== this.sid) {
        this.reset();
        this.kind = p.kind;
        this.sid = p.sid;
      }
      this.total = p.total;
      this.got.set(0, p);
      const pre: Map<number, ChunkPayload> | undefined = this.early.get(p.sid);
      if (pre !== undefined) {
        this.early.delete(p.sid);
        pre.forEach((v: ChunkPayload, k: number) => {
          if (k > 0 && k < this.total) {
            this.got.set(k, v);
          }
        });
      }
      // 预收片只留最近几轮，防内存膨胀（正常一轮就会全部收编）
      while (this.early.size > 3) {
        const first: number | undefined = this.early.keys().next().value;
        if (first === undefined) {
          break;
        }
        this.early.delete(first);
      }
    } else if (p.kind === this.kind && p.sid === this.sid && p.seq < this.total) {
      // 当前轮的乱序片：直接收（Map 天然去重）
      this.got.set(p.seq, p);
    } else {
      // seq0 还没来（不知道这轮的 sid 对不对）：先暂存，等 seq0 到了再对号
      let m: Map<number, ChunkPayload> | undefined = this.early.get(p.sid);
      if (m === undefined) {
        m = new Map<number, ChunkPayload>();
        this.early.set(p.sid, m);
      }
      m.set(p.seq, p);
    }
    return this.total > 0 && this.got.size >= this.total;
  }

  /** 取走拼好的条目（按 seq 顺序拼回，多段条目还原成完整 JSON 再反序列化）并清空 */
  take(): Object[] {
    const pieces: ChunkPiece[] = [];
    for (let s = 0; s < this.total; s++) {
      const c: ChunkPayload | undefined = this.got.get(s);
      if (c === undefined) {
        continue;
      }
      for (let i = 0; i < c.items.length; i++) {
        pieces.push(c.items[i]);
      }
    }
    const order: number[] = [];
    const byFid: Map<number, ChunkPiece[]> = new Map<number, ChunkPiece[]>();
    for (let i = 0; i < pieces.length; i++) {
      const pc: ChunkPiece = pieces[i];
      if (pc === undefined || pc === null) {
        continue;
      }
      const arr: ChunkPiece[] | undefined = byFid.get(pc.fid);
      if (arr === undefined) {
        byFid.set(pc.fid, [pc]);
        order.push(pc.fid);
      } else {
        arr.push(pc);
      }
    }
    const out: Object[] = [];
    for (let i = 0; i < order.length; i++) {
      const arr: ChunkPiece[] | undefined = byFid.get(order[i]);
      if (arr === undefined) {
        continue;
      }
      arr.sort((a: ChunkPiece, b: ChunkPiece): number => a.part - b.part);
      const expect: number = arr[0].parts;
      if (arr.length !== expect) {
        Logger.w(`ChunkAssembler.take: 条目 #${order[i]} 段数不全（${arr.length}/${expect}），丢弃`);
        continue;
      }
      let json: string = '';
      for (let k = 0; k < arr.length; k++) {
        json += arr[k].json;
      }
      try {
        out.push(JSON.parse(json) as Object);
      } catch (err) {
        Logger.w(`ChunkAssembler.take: 条目 #${order[i]} 反序列化失败，丢弃`);
      }
    }
    this.reset();
    return out;
  }

  reset(): void {
    this.kind = '';
    this.sid = -1;
    this.total = 0;
    this.got = new Map<number, ChunkPayload>();
  }
}
