# Pull Request

## Description

What does this PR change, and why? Keep it focused; one logical change per PR.

## Related Issue

Closes #

## Type of Change

- [ ] feat — new feature
- [ ] fix — bug fix
- [ ] test — new tests or test refactor
- [ ] docs — documentation only
- [ ] chore — tooling, build, configuration
- [ ] ci — CI / GitHub Actions changes
- [ ] refactor — non-functional code restructuring
- [ ] perf — performance improvement
- [ ] breaking — backward-incompatible change (requires migration note below)

## Quality Gates (all must be checked before review)

- [ ] `forge build` clean
- [ ] `forge test -vvv` all green
- [ ] `forge coverage` line coverage ≥ 95% (or unchanged if N/A)
- [ ] `slither .` no high or medium severity findings
- [ ] `aderyn .` no high or medium severity findings
- [ ] `forge fmt --check` clean
- [ ] `forge snapshot --check` no unexplained gas regression
- [ ] NatSpec present on new public, external, or state-changing internal functions
- [ ] No emoji glyphs in committed files (rule: `CLAUDE.md`)
- [ ] No AI attribution in commit messages or files (rule: `CLAUDE.md`)

## Conventional Commit

Commit follows the closed scope set:

`feat | fix | test | docs | chore | ci | refactor | perf` × `vault | verifier | identity | whitelist | ci | docs | tests | deploy | social | infra`

Example: `feat(vault): add decimals offset for inflation defense`

## Breaking Change Note (if applicable)

If this PR breaks an existing API or storage layout, describe:

- What broke
- Migration steps for downstream users
- Whether existing tests still pass without modification

## Additional Notes

Anything reviewers should look at first, performance characteristics, edge cases not yet covered, follow-up PRs you plan to open, etc.
