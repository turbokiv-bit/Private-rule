# CN Additional List for Surge

每天由 GitHub Actions 自动下载以下域名列表，并转换为 Surge Rule Set：

- 上游：<https://static-file-global.353355.xyz/rules/cn-additional-list.txt>
- 原始副本：`source/cn-additional-list.txt`
- Surge 规则：`rules/cn-additional-list-surge.list`

## Surge 中使用

将仓库设为公开仓库后，在 Surge 配置的 `[Rule]` 中加入：

```ini
RULE-SET,https://raw.githubusercontent.com/你的用户名/你的仓库名/main/rules/cn-additional-list-surge.list,DIRECT
```

如果这些域名需要走某个策略组，将最后的 `DIRECT` 换成策略组名称，例如：

```ini
RULE-SET,https://raw.githubusercontent.com/你的用户名/你的仓库名/main/rules/cn-additional-list-surge.list,Proxy
```

## 自动更新时间

工作流每天北京时间/香港时间 **04:00** 运行，也可以在 GitHub 仓库的 **Actions → Update Surge rules → Run workflow** 手动运行。

GitHub 的定时任务可能有几分钟到几十分钟延迟。只有上游内容发生变化时才会创建新提交。

## 转换规则

上游每个域名：

```text
example.com
```

会转换为：

```text
DOMAIN-SUFFIX,example.com
```

脚本会进行域名格式校验、去重和排序；下载失败或内容无效时不会覆盖已有文件。

## 首次启用

1. 新建 GitHub 仓库，默认分支使用 `main`。
2. 将本项目中的全部文件上传并提交。
3. 打开仓库的 **Actions** 页面，启用工作流。
4. 手动运行一次 `Update Surge rules`，或等待每日定时运行。
5. 如果工作流无法推送，请在仓库 **Settings → Actions → General → Workflow permissions** 中选择 **Read and write permissions**。
