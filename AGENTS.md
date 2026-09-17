# 项目协作规范 / Project Contribution Rules

## Git 提交 / Git commits

- 所有新 Git commit 的提交信息必须同时包含中文和英文，包括功能、修复、文档、测试、合并和回退提交。
- Every new Git commit message must contain both Chinese and English, including feature, fix, documentation, test, merge, and revert commits.
- 推荐格式 / Recommended format: `type: 中文说明 / English description`
- 示例 / Example: `feat: 安装全局命令 / Install the global CLI command`
- 不为修改历史提交信息而重写已经推送的历史，除非用户明确要求。
- Do not rewrite published history solely to change commit messages unless explicitly requested.

## 开发完成流程 / Development Completion Workflow

- 每项开发任务完成后，及时运行相关测试、语法检查与 `git diff --check`，检查变更范围；测试通过后，立即使用中英双语提交信息 commit，并 push 到当前分支对应的远程分支，无需再次等待用户提醒。
- After completing each development task, promptly run relevant tests, syntax checks, and `git diff --check`, and review the scope of changes. Once checks pass, commit with a bilingual Chinese/English message and push to the current branch's corresponding remote branch without waiting for another reminder.
- 仅提交当前任务及用户明确要求一并交付的改动，不夹带无关修改、密钥或敏感配置。
- Commit only changes belonging to the task or explicitly requested for delivery; exclude unrelated changes, secrets, and sensitive configuration.
- 测试失败时先修复并重新测试，不以失败状态宣告完成。若测试、commit 或 push 被环境、权限、网络或远程冲突阻塞，明确报告阻塞和实际完成状态；不得绕过检查或默认强制推送。
- Fix failing tests and rerun them before declaring completion. If testing, committing, or pushing is blocked by the environment, permissions, network, or remote conflicts, report the blocker and actual status; do not bypass checks or force-push by default.
- 完成回复说明验证结果、commit 标识和 push 结果。用户当次明确要求不提交或不推送时，以该要求为准。
- Final responses must state verification results, the commit identifier, and push status. An explicit user request not to commit or push takes precedence.

## 验证 / Verification

- 防火墙相关测试应使用 mock 或隔离环境，不在开发主机上修改真实 UFW 规则。
- Use mocks or isolated environments for firewall tests; do not modify real UFW rules on the development host.
