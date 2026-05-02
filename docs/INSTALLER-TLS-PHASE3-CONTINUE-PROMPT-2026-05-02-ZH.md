继续 `github-mirror-template` 的 interactive installer TLS / ACME 这条线。先不要重做上下文整理，直接把当前停点接起来。

仓库与分支：
- repo: `/root/.openclaw/workspace/research/github-mirror-template`
- branch: `weiyusc/exp/interactive-installer`

开始前先做：
1. `git checkout weiyusc/exp/interactive-installer`
2. `git pull --ff-only`
3. 运行并确认通过：
   - `bash tests/installer-contracts-regression.sh`
   - `bash tests/installer-doctor-golden.sh`
   - `bash tests/installer-smoke.sh`
   - `bash tests/deploy-config-yaml-regression.sh`

先读这些文件，按这个顺序：
1. `docs/INSTALLER-TLS-PHASE3-HANDOFF-2026-05-02-ZH.md`
2. `docs/INSTALLER-TLS-PHASE2-HANDOFF-2026-05-02-ZH.md`
3. `docs/INSTALLER-TLS-PHASE1-HANDOFF-2026-05-01-ZH.md`
4. `docs/INSTALLER-RESULT-CONTRACTS-ZH.md`
5. `docs/INSTALLER-STATE-MODEL-ZH.md`
6. `docs/INSTALLER-OPERATOR-RUNBOOK-ZH.md`

当前稳定停点：
- `ACME-ISSUANCE-RESULT` 已显式区分两类：
  - conservative placeholder
  - synthetic non-placeholder future real execute attempt
- `doctor/resume/regression` 已不再靠 `final_status=blocked` 这类宽条件误判 placeholder
- 最新已推送提交：`4ba103f feat: formalize ACME placeholder and real-execute fixture boundaries`

本次续做的首要目标：
- 不要直接接真实 ACME runtime
- 先把 **non-placeholder future real execute attempt** 的 strategy / doctor / resume 语义补清

建议优先做：
1. 评估是否需要新增独立 strategy（例如 `inspect-after-real-execute-attempt`）
2. 若不新增 strategy，也要明确：
   - `client_invoked=true`
   - `real_execution_performed=true`
   - `final_status=blocked`
   这一类结果在 doctor / resume / operator hint 中如何稳定解释
3. 补 contract regression / doctor golden / 文档，确保它不会再回归成 placeholder 判定
4. 只有这层 control-plane 清楚之后，再考虑真实 ACME client execute 接线

约束：
- 不要把 synthetic fixture 当成真实 runtime 已接通
- 不要退回到宽条件猜测 placeholder
- 保持保守边界：先 contract clarity，再 runtime completeness

完成后请给出：
- 改了哪些文件
- 为什么这样定 strategy
- 跑了哪些测试，结果如何
- 是否已 commit / push
