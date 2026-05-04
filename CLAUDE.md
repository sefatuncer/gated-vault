# CLAUDE.md — gated-vault

ERC-4626 yield vault gated by W3C Verifiable Credentials. Compliant DeFi pattern referansı (eIDAS 2.0 / MiCA / RWA bağlamı).

**Stack:** Solidity + Foundry + OpenZeppelin Contracts (sürümler `foundry.toml` ve `lib/` submodule'lerinde pin'li — tek doğru kaynak orası). Credo TS + OpenID4VC + Fastify (`verifier-service/`, `package.json`'a göre). GitHub Actions CI.

**Hedef:** v1.0.0 — production-ready testnet (Sepolia, Base Sepolia, Arbitrum Sepolia). **Mainnet YOK** (eğitim/portfolio).

---

## DO NOT (kesin yasaklar)

- **Claude-Code imzası KESİNLİKLE YASAK.** Hiçbir bağlamda — git commit, push, branch ismi, PR/issue, blog post, README, tweet, LinkedIn, dev.to, mülakat materyali, video açıklaması, demo metni — `Co-Authored-By: Claude`, `Co-Authored-By: Anthropic`, `🤖`, "Generated with Claude Code", "Claude wrote this", "Built with Claude", "AI-assisted" gibi atıf/imza **geçmez**. Bu projenin **tek contributor'ı Sefa Tunçer**'dir.
  - Git config zorunlu: `user.name = "Sefa Tunçer"`, `user.email = "tuncersefa@gmail.com"`. Başka author/committer kimliği kabul edilmez.
  - Her commit sonrası doğrulama: `git log -1 --format='%an <%ae>%n%B'` çıktısında sadece Sefa görünmeli, "Claude" / "Anthropic" / "🤖" / "Generated with" pattern'lerinin **hiçbiri** olmamalı.
  - Push öncesi son tarama: `git log --format='%B' origin/main..HEAD | grep -iE '(claude|anthropic|🤖|generated with|co-authored-by:)'` — sıfır match olmalı, varsa rebase ile temizlenir, push edilmez.
- **`git add .` ve `git add -A` kullanılmaz.** Dosyalar tek tek stage edilir (kazara `.env`, `lib/`, `broadcast/`, `research/` commit'lenmesin).
- **Mainnet'a deploy yok.** Sadece testnet. Mainnet RPC veya mainnet private key ortam değişkeni eklenmez.
- **`research/` commit'lenmez.** `.gitignore`'da; paper, benchmark raw, social-evidence orada.
- **Atomic todo atlanmaz.** `blocked_by` çözülmeden başlatılmaz.
- **Hook'lar bypass edilmez.** `--no-verify`, `--no-gpg-sign` kullanılmaz; pre-commit/pre-push hook fail ederse kök sebep çözülür.

---

## LFG Döngüsü (her atomic todo)

```
/plan <id>  →  /work  →  /review  →  /social <id>  →  /compound  →  /deploy
```

- Toplam 1-3 saat. Aşıyorsa todo bölünür (`08a`, `08b`).
- `/social` çıktısı: `.claude/social/tweets/NN-slug.md` post paketi. **Humanize 3-pass zorunlu** (`.claude/social/humanize.md`). Faz 0-6 yayın yok, sadece draft. Sayısal iddia varsa kaynak: `research/social-evidence/`.
- `/compound` çıktıları: `.claude/solutions/` (Claude için pattern) **+** `learn/` (Sefa için pedagojik teaching note + mülakat Q&A) **+** `progress.md` güncelleme.

## Teaching Pass (`learn/` — public, mülakat-hazır)

- `learn/` klasörü: konu bazlı 30-50 deep note + `interview-prep/` Q&A digest.
- Her `/compound` adımında ilgili note(lar) güncellenir; topic uyumsuzsa skip ok.
- Note'ların kalite yapısı: konsept → mekanizma → bizim kod → tuzak → mülakat sorusu → ileri okuma.
- Detay: `learn/README.md` + `learn/INDEX.md`. Şablon: `learn/_template.md`.

## Environment Strategy (özet — detay: `.claude/solutions/env-strategy.md`)

**Hibrit:** inner loop lokal, multi-service e2e Docker, deploy artifact Docker.

- **Lokal:** Foundry (forge/anvil/cast), Slither (pipx), Aderyn (binary), Halmos/Mythril (Faz 7), verifier-service dev (`npm run dev`).
- **Docker:** mock issuer + did:web (Faz 4 `docker-compose.dev.yml`), tam E2E (Faz 5 `docker-compose.e2e.yml`), verifier-service production image (Faz 5 todo-51).
- **CI:** GitHub Actions matrix — foundry native + verifier node image + e2e compose.
- **YOK:** root-level Dockerfile yok; Foundry'yi Docker'da koşturma (5-20x yavaşlama).

---

## Quality Gates (merge için zorunlu)

| Kapı | Eşik | Komut |
|---|---|---|
| Tests | tüm yeşil | `forge test -vvv` |
| Line coverage | ≥ %95 | `forge coverage --report lcov` |
| Slither | high + medium = 0 | `slither .` |
| Aderyn | high + medium = 0 | `aderyn .` |
| Format | clean | `forge fmt --check` |
| Gas regression | snapshot eşit | `forge snapshot --check` |
| NatSpec | %100 (public/external + internal state-changing) | manuel review + solhint |
| Verifier-service | lint + test yeşil | `cd verifier-service && npm run lint && npm test` |

`bool: any-fail → block`. Faz 6 (CI) sonrası bu kapılar GitHub Actions'ta otomatik.

---

## Conventional Commits (scope kümesi kapalı)

```
feat(scope):  fix(scope):  test(scope):
docs(scope):  ci(scope):   chore(scope):  refactor(scope):
```

**Geçerli scope:** `vault`, `verifier`, `identity`, `whitelist`, `ci`, `docs`, `tests`, `deploy`, `social`, `infra`. Bu küme dışında scope eklenmez.

İyi: `feat(vault): add decimals offset for inflation defense`
Kötü: `update vault stuff` / `feat(misc): ...`

---

## Klasör Haritası

```
.claude/
├── commands/     slash komutlar (lfg, plan, work, review, social, compound, deploy)
├── plans/        günlük plan dosyaları (YYYY-MM-DD-todo-NN.md)
├── solutions/    yeniden kullanılabilir pattern'ler
├── social/       tweet paketleri, viral radar, humanize disiplini, image prompt'lar
├── todos/        116 atomic todo (00 → 116, sırayla)
└── progress.md   overall tracker

contracts/        Solidity kaynak (interfaces/, libraries/, mocks/, identity/)
test/             Foundry test (unit/, fuzz/, invariant/, integration/)
script/deploy/    Forge Script (testnet deploy)
verifier-service/ Credo TS + Fastify (off-chain VC verifier)

research/         ⚠️ git-ignored — paper, benchmark raw, ADR, literature, social-evidence/
learn/            mülakat-hazır pedagojik note'lar + interview-prep/ Q&A (public)
```

---

## Komut Cheatsheet

```bash
# Smart contracts
forge build
forge test -vvv
forge test --match-contract GatedVault --fuzz-runs 10000
forge coverage --report lcov                    # CI'da Codecov'a yüklenir
forge snapshot                                  # baseline (commit edilir)
forge snapshot --check                          # gas regression gate
forge fmt                                       # auto-format
forge fmt --check                               # CI gate

# Static analysis
slither .                                       # high+medium = 0 hedef
aderyn .                                        # config: aderyn.toml

# İleri analiz (Faz 7+)
halmos --function check_                        # symbolic execution
myth analyze contracts/<File>.sol               # mythril (opsiyonel)

# Off-chain (verifier-service/)
cd verifier-service
npm install
npm run build
npm run lint
npm test
npm run dev                                     # local fastify

# Testnet deploy (mainnet YASAK)
forge script script/deploy/<Name>.s.sol \
  --rpc-url $SEPOLIA_RPC --broadcast --verify
```

---

## Sürekli Kalite Kuralları (kod yazarken)

- **Custom errors**, `require(string)` değil. Gas + UX.
- **`SafeERC20.safeTransfer`/`safeTransferFrom`**, çıplak `transfer` yok.
- **Checks-Effects-Interactions** (CEI) sırası. State değişikliği önce, external call sonra.
- **`ReentrancyGuard`** state-changing external entrypoint'lerde.
- **Rounding direction**: ERC-4626 boundary'lerinde **vault lehine** (Floor on share-mint, Ceil on share-burn).
- **EIP-712 typed data** off-chain imza için; çıplak `eth_sign`/EIP-191 kullanılmaz.
- **Replay protection**: nonce + chainId + domain separator zorunlu off-chain → on-chain bridging'de.
- **NatSpec**: `@title`, `@author "Sefa Tunçer"`, `@notice`, `@dev`, `@param`, `@return`. Public/external'da %100.

---

## Başlamadan Önce

1. `.claude/todos/00-orchestration.md` oku — 12 fazlı plan.
2. `.claude/todos/00-OVERVIEW.md` oku — mimari + use case.
3. `.claude/progress.md`'de **devam eden todo** ne, oradan başla. Hiç yoksa `01-foundry-init.md`.
4. Bağımlılık çözülmeden todo başlatılmaz (`blocked_by`).

---

## Detay Pointer'ları (CLAUDE.md tek doğru kaynak değil)

- **Sürüm pinleri:** `foundry.toml`, `verifier-service/package.json`, `lib/` git submodule'leri
- **Sosyal medya operasyonu:** `.claude/social/README.md`
- **Humanize disiplini:** `.claude/social/humanize.md`
- **Article / tweet kanıtları:** `research/social-evidence/README.md`
- **Teaching külliyatı (learn/):** `learn/README.md` + `learn/INDEX.md`
- **Environment strategy (Docker / lokal):** `.claude/solutions/env-strategy.md`
- **Faz haritası:** `.claude/todos/README.md`
- **Mevcut todo durumu:** `.claude/progress.md`
