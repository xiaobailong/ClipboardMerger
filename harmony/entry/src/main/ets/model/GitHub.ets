import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

const PREF_STORE: string = 'clipboard_merger_settings';
const K_OWNER: string = 'gh_owner';
const K_REPO: string = 'gh_repo';
const K_PATH: string = 'gh_path';
const K_BRANCH: string = 'gh_branch';
const K_TOKEN: string = 'gh_token';

export interface GhConfig {
  owner: string;
  repo: string;
  path: string;
  branch: string;
  token: string;
}

interface GhContent {
  content?: string;
  sha?: string;
}

interface GhPutBody {
  message: string;
  content: string;
  branch: string;
  sha?: string;
}

/**
 * GitHub 内容同步（对齐 Android 版 GitHubHelper：拉取/保存仓库里的指定文件）
 * 只在 UIAbility 侧使用（输入法 Extension 受基础访问模式限制不能联网）。
 */
export class GitHubStore {
  private static ctx: common.Context | undefined = undefined;
  private static cfg: GhConfig = { owner: '', repo: '', path: '', branch: 'main', token: '' };

  static init(context: common.Context): void {
    GitHubStore.ctx = context;
    GitHubStore.load();
  }

  static load(): void {
    if (GitHubStore.ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(GitHubStore.ctx, { name: PREF_STORE });
      const owner: preferences.ValueType = store.getSync(K_OWNER, '');
      const repo: preferences.ValueType = store.getSync(K_REPO, '');
      const path: preferences.ValueType = store.getSync(K_PATH, '');
      const branch: preferences.ValueType = store.getSync(K_BRANCH, 'main');
      const token: preferences.ValueType = store.getSync(K_TOKEN, '');
      GitHubStore.cfg = GitHubStore.normalize({
        owner: typeof owner === 'string' ? owner : '',
        repo: typeof repo === 'string' ? repo : '',
        path: typeof path === 'string' ? path : '',
        branch: typeof branch === 'string' && branch !== '' ? branch : 'main',
        token: typeof token === 'string' ? token : ''
      });
    } catch (err) {
      Logger.w('GitHubStore.load failed');
    }
    Logger.d(`GitHubStore.load: owner=${GitHubStore.cfg.owner}, repo=${GitHubStore.cfg.repo}, path=${GitHubStore.cfg.path}`);
  }

  static save(cfg: GhConfig): void {
    GitHubStore.cfg = GitHubStore.normalize(cfg);
    const c: GhConfig = GitHubStore.cfg;
    if (GitHubStore.ctx !== undefined) {
      try {
        const store = preferences.getPreferencesSync(GitHubStore.ctx, { name: PREF_STORE });
        store.putSync(K_OWNER, c.owner);
        store.putSync(K_REPO, c.repo);
        store.putSync(K_PATH, c.path);
        store.putSync(K_BRANCH, c.branch);
        store.putSync(K_TOKEN, c.token);
        store.flushSync();
      } catch (err) {
        Logger.w('GitHubStore.save: persist failed');
      }
    }
    Logger.d(`GitHubStore.save: done owner=${c.owner} repo=${c.repo} path=${c.path} branch=${c.branch}`);
  }

  /**
   * 规整配置：去掉首尾空格、路径首尾多余的 '/'、分支为空退回 main。
   * 排查 GitHub 404 时的高频真因：输入框里多一个空格或路径写成 `/notes/x.txt`，
   * 拼出来就是 `contents//notes/x.txt` ⇒ GitHub 回 404。
   */
  private static normalize(cfg: GhConfig): GhConfig {
    let owner: string = cfg.owner.trim();
    let repo: string = cfg.repo.trim();
    let path: string = cfg.path.trim();
    // 兼容"仓库名"里粘了整条 Git 地址。
    // 真机日志实证（PIT-040）：repo 填成 https://github.com/xiaobailong/dy-scraper.git
    // ⇒ 拼出 repos/xiaobailong/https://github.com/... ⇒ ① ② ③ 三级全 404。
    if (repo.indexOf('github.com') >= 0 || repo.endsWith('.git') || repo.indexOf('/') >= 0) {
      let full: string = repo.replace('https://', '').replace('http://', '').replace('git@', '');
      const at: number = full.indexOf('@');
      if (at >= 0) {
        full = full.substring(at + 1);
      }
      const gh: number = full.indexOf('github.com/');
      if (gh >= 0) {
        full = full.substring(gh + 'github.com/'.length);
      }
      if (full.endsWith('.git')) {
        full = full.substring(0, full.length - 4);
      }
      while (full.startsWith('/')) {
        full = full.substring(1);
      }
      while (full.endsWith('/')) {
        full = full.substring(0, full.length - 1);
      }
      const seg: string[] = full.split('/');
      if (seg.length >= 2 && seg[0] !== '') {
        owner = seg[0];
        repo = seg[1];
      } else if (seg.length === 1 && seg[0] !== '') {
        repo = seg[0];
      }
    }
    // path 去掉首尾 '/'：`/notes/a.txt` 会拼成 contents//notes/a.txt ⇒ 404
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    const branch: string = cfg.branch.trim() === '' ? 'main' : cfg.branch.trim();
    if (owner !== cfg.owner.trim() || repo !== cfg.repo.trim()) {
      Logger.d(`GitHubStore.normalize: repo 字段含完整地址，已解析为 owner=${owner} repo=${repo}`);
    }
    return {
      owner: owner,
      repo: repo,
      path: path,
      branch: branch,
      token: cfg.token.trim()
    };
  }

  /**
   * 自诊断：拿 repo / 分支 / 文件三级 URL 分别探一次，拼成一段可读报告。
   * 主界面点「诊断 404」直接显示结果 ⇒ 不用捞日志也能定论是哪一级错了。
   */
  static async diagnose(): Promise<string> {
    const c: GhConfig = GitHubStore.cfg;
    const lines: string[] = [];
    lines.push(`owner="${c.owner}" repo="${c.repo}" path="${c.path}" branch="${c.branch}" token长度=${c.token.length}`);
    const base: string = `https://api.github.com/repos/${c.owner}/${c.repo}`;
    const probes: string[] = [
      base,
      `${base}/branches/${c.branch}`,
      `${base}/contents/${c.path}?ref=${c.branch}`
    ];
    const names: string[] = ['① 仓库', '② 分支', '③ 文件'];
    for (let i = 0; i < probes.length; i++) {
      try {
        const r = await http.createHttp().request(probes[i], GitHubStore.options(http.RequestMethod.GET));
        lines.push(`${names[i]} HTTP ${r.responseCode} → ${String(r.result).substring(0, 110)}`);
      } catch (err) {
        const e = err as BusinessError;
        lines.push(`${names[i]} 请求异常 code=${e.code} ${e.message}`);
      }
    }
    lines.push('（① 404 ⇒ owner/repo 或 token 无权限；② 404 ⇒ 分支名错；③ 404 ⇒ 路径错或文件不存在）');
    Logger.w(`gh diagnose:\n${lines.join('\n')}`);
    return lines.join('\n');
  }

  static current(): GhConfig {
    return GitHubStore.cfg;
  }

  static configured(): boolean {
    const c: GhConfig = GitHubStore.cfg;
    return c.owner !== '' && c.repo !== '' && c.path !== '';
  }

  private static url(): string {
    const c: GhConfig = GitHubStore.cfg;
    return `https://api.github.com/repos/${c.owner}/${c.repo}/contents/${c.path}`;
  }

  private static headers(): Record<string, string> {
    const h: Record<string, string> = {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'JianJi-HarmonyOS',
      'X-GitHub-Api-Version': '2022-11-28'
    };
    if (GitHubStore.cfg.token !== '') {
      h['Authorization'] = `Bearer ${GitHubStore.cfg.token}`;
    }
    return h;
  }

  private static toBase64(text: string): string {
    // 空文件是正常情况：Base64Helper 对空串会抛 -2（Parameter error）
    // 真机日志：保存空内容 / 拉取 0 字节文件时都会走到这里
    if (text.length === 0) {
      return '';
    }
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  private static fromBase64(b64: string): string {
    // 同上：0 字节文件 GitHub 返回 "content": ""，对它 decode 会抛 -2
    if (b64 === '') {
      return '';
    }
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(b64);
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }

  private static options(method: http.RequestMethod, extra?: string): http.HttpRequestOptions {
    const opts: http.HttpRequestOptions = {
      method: method,
      header: GitHubStore.headers(),
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      readTimeout: 20000
    };
    if (extra !== undefined) {
      opts.extraData = extra;
    }
    return opts;
  }

  /** 拉取文件内容（返回文本；同时把 sha 记到 cfg 里供保存用） */
  static async fetch(): Promise<string> {
    const c: GhConfig = GitHubStore.cfg;
    const url: string = `${GitHubStore.url()}?ref=${c.branch}`;
    const resp = await http.createHttp().request(
      url, GitHubStore.options(http.RequestMethod.GET));
    if (resp.responseCode !== 200) {
      Logger.w(`gh fetch ${resp.responseCode} url=${url} body=${String(resp.result).substring(0, 200)}`);
      throw new Error(`获取失败 HTTP ${resp.responseCode}（${url}）: ${String(resp.result).substring(0, 120)}`);
    }
    const body: string = resp.result as string;
    const obj: GhContent = JSON.parse(body) as GhContent;
    if (obj.sha !== undefined) {
      GitHubStore.lastSha = obj.sha;
    }
    const raw: string = obj.content === undefined ? '' : obj.content;
    return GitHubStore.fromBase64(raw.replace(/\r?\n/g, ''));
  }

  /** 保存文本到仓库文件（已存在则带 sha 覆盖，不存在则新建） */
  static async saveContent(text: string): Promise<void> {
    const c: GhConfig = GitHubStore.cfg;
    // 先取 sha（存在则覆盖；不存在会 404，忽略）
    try {
      const head = await http.createHttp().request(
        `${GitHubStore.url()}?ref=${c.branch}`, GitHubStore.options(http.RequestMethod.GET));
      if (head.responseCode === 200) {
        const obj: GhContent = JSON.parse(head.result as string) as GhContent;
        GitHubStore.lastSha = obj.sha === undefined ? '' : obj.sha;
      } else {
        GitHubStore.lastSha = '';
      }
    } catch (err) {
      GitHubStore.lastSha = '';
    }

    const payload: GhPutBody = {
      message: `update ${c.path} by JianJi`,
      content: GitHubStore.toBase64(text),
      branch: c.branch
    };
    if (GitHubStore.lastSha !== '') {
      payload.sha = GitHubStore.lastSha;
    }
    const resp = await http.createHttp().request(GitHubStore.url(),
      GitHubStore.options(http.RequestMethod.PUT, JSON.stringify(payload)));
    if (resp.responseCode !== 200 && resp.responseCode !== 201) {
      Logger.w(`gh save ${resp.responseCode} url=${GitHubStore.url()} body=${String(resp.result).substring(0, 200)}`);
      throw new Error(`保存失败 HTTP ${resp.responseCode}（${GitHubStore.url()}）: ${String(resp.result).substring(0, 120)}`);
    }
    Logger.d(`GitHubStore.save: ok (${text.length} chars)`);
  }

  private static lastSha: string = '';
}
