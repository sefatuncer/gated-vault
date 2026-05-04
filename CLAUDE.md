# CLAUDE.md — gated-vault

ERC-4626 yield vault gated by W3C Verifiable Credentials. Compliant DeFi pattern referansı (eIDAS 2.0 / MiCA / RWA bağlamı).

**Stack:** Solidity + Foundry + OpenZeppelin Contracts (sürümler `foundry.toml` ve `lib/` submodule'lerinde pin'li — tek doğru kaynak orası). Credo TS + OpenID4VC + Fastify (`verifier-service/`, `package.json`'a göre). GitHub Actions CI.

**Hedef:** v1.0.0 — production-ready testnet (Sepolia, Base Sepolia, Arbitrum Sepolia). **Mainnet YOK** (eğitim/portfolio).

---

## DO NOT (kesin yasaklar)

- **Claude-Code imzası KESİNLİKLE YASAK.** Hiçbir bağlamda — git commit, push, branch ismi, PR/issue, blog post, README, tweet, LinkedIn, dev.to, mülakat materyali, video açıklaması, demo metni — `Co-Authored-By: Claude`, `Co-Authored-By: Anthropic`, ``, "Generated with Claude Code", "Claude wrote this", "Built with Claude", "AI-assisted" gibi atıf/imza **geçmez**. Bu projenin **tek contributor'ı Sefa Tunçer**'dir.
  - **Kod içi izler dahil yasak:** Solidity custom error/event mesajları, `console.log`, `revert` mesajları, Bash `echo` log'ları, test trace'leri, NatSpec, `@author`, JSDoc, TS log mesajları, README banner'ları, error code'ları, tweet metni, X article, LinkedIn post, image prompt, demo script. Hiçbirinde "Claude", "Anthropic", "" veya AI atıfı bulunmaz.
  - **Emoji KESİNLİKLE YASAK.** Kod, dosya, commit mesajı, doc, README, NatSpec, Bash log/echo, test output, CLAUDE.md / `learn/` / `.claude/` / `research/` markdown'ları, tweet, image prompt, demo metni, chat yanıtı — **hiçbirinde** Unicode emoji glyph'i geçmez. AI-çağrışımlı semboller (robot, sihirli değnek, kıvılcım, roket, parti şapkası tarzı) kesinlikle. Sözde fonksiyonel görünenler (check / cross / warning üçgeni / hourglass / yeşil-kırmızı-mavi-sarı daire / push pin / target / ampul / fidan / ağaç / şeftali / ateş / göz / kalpli el / köprü / iplik / yıldız / inşaat işareti) de yasak — bunlar Claude'un proaktif alışkanlığı, Sefa'nın doğal yazımında yer almıyor. Yerine: düz kelime ("OK" / "fail" / "uyarı" / "TODO" / "WIP"), markdown checkbox (`[x]` / `[ ]`), veya hiç işaret koymayıp düz cümle.
  - **Claude AI-alışkanlıklarından uzak dur** (kod, doküman, **ve chat yanıtları dahil**). `.claude/social/humanize.md`'de listelenen AI-tell pattern'leri proje dokümantasyonu ve chat tonunda da geçerli:
    - **Yasak sözcükler:** leverage / utilize / delve / robust / comprehensive / seamless / elevate / unlock / foster / landscape (figüratif) / journey / embark / dive into / craft / streamline / cutting-edge / state-of-the-art.
    - **Yasak yapılar:** em dash bombası (>1 / paragraf), aşırı üçlü paralel ("X, Y, and Z" her cümlede), "Here's why ↓", "Let me explain", "In conclusion", "Crucially / Notably / Importantly", yapay coşku ("Excited to share", "Game changer", "Mind blown", "Absolutely insane").
    - **Yasak açılışlar:** "Excited to share", "Strap in", "TIL", "Just published", "Thread " (hem emoji hem klişe).
    - **Yapısal kural:** kısa cümle varyansı, kısaltmalar açık (`I'm`, `don't`, `won't`), bir voice signature (zaman işareti / mikro itiraf / soru) — robotik tam-yapı tabakası değil.
  - Git config zorunlu: `user.name = "Sefa Tunçer"`, `user.email = "tuncersefa@gmail.com"`. Başka author/committer kimliği kabul edilmez.
  - Her commit sonrası doğrulama: `git log -1 --format='%an <%ae>%n%B'` çıktısında sadece Sefa görünmeli, "Claude" / "Anthropic" / "" / "Generated with" pattern'lerinin **hiçbiri** olmamalı.
  - Push öncesi son tarama (commit mesajları **ve** dosya içerikleri) — **atıf-deseni odaklı precision grep**:
    ```
    git log --format='%B' origin/main..HEAD | grep -iE '(co-authored-by:[[:space:]]*(claude|anthropic)|generated with claude||claude wrote|built with claude|ai-assisted by)'
    git diff origin/main..HEAD -- ':!CLAUDE.md' ':!.claude/**/*.md' ':!learn/**/*.md' | grep -iE '(co-authored-by:[[:space:]]*(claude|anthropic)|generated with claude||claude wrote)'
    ```
    Her iki tarama da sıfır match olmalı; aksi halde rebase / dosya temizlik yapılır, push edilmez.
  - **Kural-tarif istisnası:** CLAUDE.md, `.claude/**/*.md` (solutions, social, todos), ve `learn/**/*.md` dosyalarında "Claude" / "Anthropic" / "Claude-Code" sözcükleri **kuralın kendisini tarif eden metin** olarak geçebilir (bu paragraf gibi). Ayrıca `.claude/` klasör adı ve `CLAUDE.md` dosya adı Claude Code convention'ı; değiştirilmez. **Atıf veya imza** (örn. `Co-Authored-By: Claude`, `generated`) hiçbir bağlamda geçmez.
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

## Teaching Pass (`learn/` — local, Blockchain Developer mülakat-hazır)

- `learn/` klasörü gitignored (kişisel öğrenme + teknik mülakat korpusu).
- Her `/compound` adımında ilgili note(lar) güncellenir; topic uyumsuzsa skip ok.
- **Operasyonel günlük yasak:** "ne yaptık, dosya yolu, komut, push ladık, hata mesajını yapıştır" formatı **learn/ dışı** — bunlar `progress.md` ve `.claude/solutions/`'a gider. `learn/` notları **konsept derinliği** taşır.
- **Zorunlu teknik depth yapısı:**
  1. **TL;DR** — mülakatta 30 saniyede ne anlatırsın
  2. **Tarihsel bağlam** — bu konsept ne zaman, kim, neden çıkardı? Hangi acıyı çözdü?
  3. **Spec / Mekanizma** — adım adım, EVM seviyesinde (opcode, storage layout, gas profili, state transition). Diagram ASCII art ok.
  4. **Implementation patterns** — OZ vs Solady vs custom; trade-off'lar (gas, audit history, API surface); ne zaman hangisi.
  5. **Bug history / real incidents** — bu konsepte bağlı protokoller hangi hatadan kaybetti? (örn. Sushiswap, Sonne, Imbtc, MultiSig 2017). Vector + lesson.
  6. **Mülakat Q&A** — 4-7 soru, **junior / mid / senior** dengesi + en az 1 whiteboard (kod yazma) sorusu. Format: kısa cevap (30 sn sözel) + derin cevap (2-3 dk) + mülakatçı tuzağı (follow-up'ta sıklıkla nereye dönüyor).
- "Bizim cycle'da yaptık" satırları **yasak**. Eğer cycle deneyimi konsepti aydınlatıyorsa 1-2 cümle anchor olabilir, ana içerik değil.
- Hedef 600-1500 kelime / note (teknik depth zorunlu kıldığı için). Şişirme yine yasak; her cümle bilgi taşımalı, jargon parantezli açıklanır.
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

research/         (git-ignored) — paper, benchmark raw, ADR, literature, social-evidence/
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
- **Toxic asset reject**: vault deploy-time `supportsInterface(0xe58e113c)` ile **ERC-777 reject** (Imbtc dForce 2020, $25M reentrancy). Fee-on-transfer / rebase token detection: deploy-time `try { token.balanceOf(self) }` pre-call/post-call diff testi; tespitte reject.
- **Tracked AUM accounting**: `totalAssets()` override + `_accountedAssets` (Sonne 2022 $20M, Cream 2021 $130M donation oracle). Naive `balanceOf(self)` yasak.
- **Inflation defense**: `_decimalsOffset()` ≥ 6 (USDC) + atomic first-deposit seed (deploy script tek tx).
- **Centralization disclosure**: owner/admin'in ne yapabildiği README'de explicit liste (transferOwnership, harvest, pause, fee-set vb.). "Trust assumptions" bölümü zorunlu.
- **NatSpec**: `@title`, `@author "Sefa Tunçer"`, `@notice`, `@dev`, `@param`, `@return`. Public/external'da %100.

## Security Disiplini

- **Threat-model-first.** Her security aracı / test / kontrol gerekçeli olmalı; "audit-grade checklist" performative kullanılmaz. Yeni güvenlik kontrolü eklerken "hangi attack vector'unu kapatıyor" sorusu cevaplanmadan eklenmez.
- **"Production-ready"** = mainnet kalitesinde testnet artefakt. Mainnet deploy YOK ama kod mainnet-grade: testnet için her bypass ("şimdilik permissive", "test'te geçici", "todo'da") yasak. İlk yazım son yazımdır.
- **Modern auditor stack** (2026): **Slither** (static, fast) + **Aderyn** (Solidity-aware static, Rust) + **Halmos** (symbolic, k-induction) + **Foundry invariant + handler** (stateful fuzz). Mythril deprecated; bizim stack dışı.
- **Defense in depth**: tek kontrol noktası yok. Inflation defense üç katman (decimals offset + tracked accounted + atomic seed); replay protection üç parça (nonce + chainId + domain separator); reentrancy iki katman (CEI sırası + ReentrancyGuard).
- **Audit-readiness ≠ audit**. Audit firmasıyla anlaşma yapılana kadar kod self-audit + threat-model + slither/aderyn/halmos clean kalır; bunlar "audit yerine geçer" kabul edilmez.

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
