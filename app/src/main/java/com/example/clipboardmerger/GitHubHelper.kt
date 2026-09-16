package com.example.clipboardmerger

import android.content.Context
import android.util.Base64
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.net.URL

class GitHubHelper(private val context: Context) {

    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun getRepoUrl(): String = prefs.getString(KEY_REPO_URL, "") ?: ""
    fun getToken(): String = prefs.getString(KEY_TOKEN, "") ?: ""
    fun getFilePath(): String = prefs.getString(KEY_FILE_PATH, "") ?: ""

    fun saveSettings(repoUrl: String, token: String, filePath: String) {
        prefs.edit()
            .putString(KEY_REPO_URL, repoUrl)
            .putString(KEY_TOKEN, token)
            .putString(KEY_FILE_PATH, filePath)
            .apply()
        Logger.d("GitHubHelper: settings saved")
    }

    fun hasSettings(): Boolean {
        return getRepoUrl().isNotBlank() && getToken().isNotBlank() && getFilePath().isNotBlank()
    }

    fun getOwnerAndRepo(): Pair<String, String>? {
        val url = getRepoUrl().trimEnd('/')
        val regex = Regex("github\\.com[:/](.+?)/(.+?)(?:\\.git)?$")
        val match = regex.find(url) ?: return null
        return Pair(match.groupValues[1], match.groupValues[2])
    }

    /**
     * 创建 HTTP 连接，自动检测并使用系统代理（WiFi 代理 / VPN / Clash 等都走这里）
     */
    private fun openConnection(url: String): HttpURLConnection {
        val uri = URI(url)
        val proxies = ProxySelector.getDefault().select(uri)
        val proxy = proxies.firstOrNull { it != Proxy.NO_PROXY }
        return if (proxy != null) {
            Logger.d("GitHubHelper: using proxy ${proxy.address()}")
            URL(url).openConnection(proxy) as HttpURLConnection
        } else {
            Logger.d("GitHubHelper: no proxy, direct connection")
            URL(url).openConnection() as HttpURLConnection
        }
    }

    fun fetchFile(): Result<String> {
        return try {
            val (owner, repo) = getOwnerAndRepo() ?: return Result.failure(Exception("无法解析仓库地址"))
            val apiUrl = "https://api.github.com/repos/$owner/$repo/contents/${getFilePath()}"
            Logger.d("GitHubHelper.fetchFile: GET $apiUrl")

            val connection = openConnection(apiUrl)
            connection.setRequestProperty("Authorization", "token ${getToken()}")
            connection.setRequestProperty("Accept", "application/vnd.github.v3+json")
            connection.setRequestProperty("User-Agent", "ClipboardMerger")
            connection.connectTimeout = 8000
            connection.readTimeout = 8000

            Logger.d("GitHubHelper.fetchFile: connecting...")
            val code = connection.responseCode
            Logger.d("GitHubHelper.fetchFile: response code=$code, contentLength=${connection.contentLength}")
            if (code != 200) {
                val errorBody = connection.errorStream?.bufferedReader()?.readText() ?: ""
                return Result.failure(Exception("HTTP $code: $errorBody"))
            }

            Logger.d("GitHubHelper.fetchFile: reading response body...")
            val response = connection.inputStream.bufferedReader().readText()
            Logger.d("GitHubHelper.fetchFile: body received, ${response.length} chars")
            val json = JSONObject(response)
            val content = json.optString("content", "")
            // 文件为空是合法场景，允许返回空字符串
            val decoded = if (content.isEmpty()) {
                Logger.d("GitHubHelper.fetchFile: success, file is empty")
                ""
            } else {
                val decodedContent = String(Base64.decode(content.replace("\n", ""), Base64.DEFAULT))
                Logger.d("GitHubHelper.fetchFile: success, ${decodedContent.length} chars")
                decodedContent
            }
            Result.success(decoded)
        } catch (e: Exception) {
            Logger.w("GitHubHelper.fetchFile failed: ${e.message}")
            Result.failure(e)
        }
    }

    fun saveFile(content: String): Result<String> {
        return try {
            val (owner, repo) = getOwnerAndRepo() ?: return Result.failure(Exception("无法解析仓库地址"))
            val apiUrl = "https://api.github.com/repos/$owner/$repo/contents/${getFilePath()}"
            Logger.d("GitHubHelper.saveFile: GET $apiUrl (for SHA)")

            var sha: String? = null
            try {
                val getConn = openConnection(apiUrl)
                getConn.setRequestProperty("Authorization", "token ${getToken()}")
                getConn.setRequestProperty("Accept", "application/vnd.github.v3+json")
                getConn.setRequestProperty("User-Agent", "ClipboardMerger")
                getConn.connectTimeout = 8000
                getConn.readTimeout = 8000
                Logger.d("GitHubHelper.saveFile: connecting to get SHA...")
                if (getConn.responseCode == 200) {
                    val getResponse = getConn.inputStream.bufferedReader().readText()
                    sha = JSONObject(getResponse).optString("sha", null)
                }
            } catch (e: Exception) {
                Logger.w("GitHubHelper.saveFile: failed to get SHA: ${e.message}")
            }

            val encoded = Base64.encodeToString(content.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            val body = JSONObject().apply {
                put("message", "Update via ClipboardMerger")
                put("content", encoded)
                if (sha != null) put("sha", sha)
            }

            Logger.d("GitHubHelper.saveFile: PUT $apiUrl")
            val connection = openConnection(apiUrl)
            connection.requestMethod = "PUT"
            connection.setRequestProperty("Authorization", "token ${getToken()}")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/vnd.github.v3+json")
            connection.doOutput = true
            connection.connectTimeout = 8000
            connection.readTimeout = 8000
            Logger.d("GitHubHelper.saveFile: connecting to PUT...")
            connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }

            val code = connection.responseCode
            Logger.d("GitHubHelper.saveFile: response code=$code")
            if (code in 200..201) {
                val resp = connection.inputStream.bufferedReader().readText()
                Logger.d("GitHubHelper.saveFile: success, HTTP $code")
                Result.success(resp)
            } else {
                val errorBody = connection.errorStream?.bufferedReader()?.readText() ?: ""
                Result.failure(Exception("HTTP $code: $errorBody"))
            }
        } catch (e: Exception) {
            Logger.w("GitHubHelper.saveFile failed: ${e.message}")
            Result.failure(e)
        }
    }

    companion object {
        private const val PREFS_NAME = "github_settings"
        private const val KEY_REPO_URL = "repo_url"
        private const val KEY_TOKEN = "token"
        private const val KEY_FILE_PATH = "file_path"
    }
}