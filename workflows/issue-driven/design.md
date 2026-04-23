# Tech Design: Issue-Driven Workflow (Shared Branch + Sequential Agents)

## Problem

Dotbot'un mevcut task modeli her task için ayrı bir `task/{shortId}-slug` branch'i açıp tamamlanınca squash-merge yapıyor. Bu, aynı feature üzerinde sıralı çalışan agent'lar (design → test-cases → implement → unit-tests → integration-tests) için yanlış:

1. **Paylaşılan branch yok**: Her agent önceki agent'ın commit'lerini görmeli ama ayrı branch açmamalı.
2. **Squash-merge erken tetikleniyor**: Her task tamamlanınca main'e merge edilmesi istenmiyor — tüm pipeline bitince tek bir PR açılmalı.
3. **Stale outputs**: Yeni run başladığında önceki run'un dosyaları (`design.md`, `test-cases.md` vb.) klasörde kalıyor, agent'lar eski içeriği okuyor.

---

## Çözüm: `shared_branch` Flag

`workflow.yaml`'a workflow seviyesinde `shared_branch` anahtarı eklendi. Bu flag set edildiğinde:

- İlk task branch + worktree oluşturur.
- Sonraki task'lar aynı worktree'yi yeniden kullanır (branch adı sabit kalır).
- Her task tamamlanınca framework `git commit + push` yapar (squash-merge yok).
- Son task ("Open PR") `gh pr create` ile PR açar.
- Worktree orphan cleanup'ı bu branch'i atlar — PR merge edilene kadar yaşamaya devam eder.

---

## Uygulanan Değişiklikler

### 1 — `workflow-manifest.ps1`: `shared_branch` Parsing

`Read-WorkflowManifest` default'larına ve fallback parser regex'ine `shared_branch` eklendi:

```powershell
$manifest = @{
    ...
    shared_branch = ""
    ...
}

# Fallback parser
if ($_ -match '^\s*(type|name|...|shared_branch)\s*:\s*(.+)$') {
    $manifest[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
}
```

---

### 2 — `WorktreeManager.psm1`: `New-TaskWorktree`'ye `BranchName` Parametresi

```powershell
function New-TaskWorktree {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot,
        [string]$BranchName = ""          # opsiyonel — verilirse override
    )
    $isSharedBranch = [bool]$BranchName
    if (-not $BranchName) {
        $BranchName = "task/$shortId-$slug"   # mevcut davranış korunuyor
    }
    # Worktree path için branch adındaki slash/özel karakterler temizlenir
    $wtSlug = $BranchName -replace '[/\\]', '-' -replace '[^a-zA-Z0-9._-]', '-'
    $worktreePath = Join-Path $worktreeDir $wtSlug
```

`worktree-map.json` entry'sine `shared_branch: $isSharedBranch` flag'i yazılır.

**Orphan cleanup koruması** (`Remove-OrphanWorktrees`):

```powershell
if ($entry.shared_branch -eq $true) { continue }   # shared branch'leri atlat
```

---

### 3 — `Invoke-WorkflowProcess.ps1`: Startup — Manifest Okuma + Placeholder Resolution

Main loop başlamadan önce:

```powershell
$sharedBranch = $null
$workflowManifest = Get-ActiveWorkflowManifest -BotRoot $botRoot
if ($workflowManifest -and $workflowManifest.shared_branch) {
    $promptFile = Join-Path $botRoot ".control\launchers\kickstart-prompt.txt"
    $resolved = $workflowManifest.shared_branch
    if (Test-Path $promptFile) {
        $issueNumber = (Get-Content $promptFile -Raw).Trim() -replace '\D', ''
        if ($issueNumber) {
            $resolved = $resolved -replace '\{input\.issue_number\}', $issueNumber
        }
    }
    # Placeholder çözülemediyse (örn. prompt dosyası eksik) shared_branch null kalır
    if ($resolved -and $resolved -notmatch '\{') {
        $sharedBranch = $resolved
    }
}
```

`{input.issue_number}` şablonu `kickstart-prompt.txt`'ten (kullanıcının UI'a girdiği değer) çözülür. Şu an desteklenen tek placeholder budur.

---

### 4 — `Invoke-WorkflowProcess.ps1`: Worktree Oluşturma

```powershell
$wtResult = New-TaskWorktree -TaskId $task.id -TaskName $task.name `
    -ProjectRoot $projectRoot -BotRoot $botRoot `
    -BranchName ($sharedBranch ?? "")
```

Aynı branch adı varsa `New-TaskWorktree` mevcut worktree'yi döndürür (yeni worktree açılmaz).

---

### 5 — `Invoke-WorkflowProcess.ps1`: Task Success — Commit + Push (squash-merge yerine)

```powershell
if ($worktreePath -and $sharedBranch) {
    $commitMsg = "task: $safeTaskName [skip ci]"
    git -C $worktreePath add -A
    git -C $worktreePath commit -m $commitMsg       # "nothing to commit" gracefully handled
    git -C $worktreePath push --set-upstream origin $sharedBranch
    # Push hatası worktree'yi veya task'ı başarısız yapmaz — sadece warn loglanır
} elseif ($worktreePath) {
    Complete-TaskWorktree ...    # Normal mod: squash-merge, değişmedi
}
```

---

### 6 — `Invoke-WorkflowProcess.ps1`: Task Failure — Worktree Koruması

```powershell
if ($worktreePath) {
    if ($sharedBranch) {
        # Worktree'yi silme: diğer task'lar aynı branch'i kullanıyor
        Write-Status "Shared branch — preserving worktree on failure" -Type Warn
    } else {
        # Normal mod: worktree temizlenir
        Remove-Junctions ... ; git worktree remove ... ; git branch -D ...
    }
}
```

---

### 7 — `server.ps1`: Outputs Cleanup (`rerun: fresh` sırasında)

`Clear-WorkflowTasks` çağrısından hemen sonra, task'lar yeniden oluşturulmadan önce:

```powershell
if ($manifest.rerun -eq 'fresh') {
    Clear-WorkflowTasks ...

    # workflow.yaml'daki outputs glob'larına uyan dosyaları sil
    foreach ($td in @($manifest.tasks)) {
        foreach ($out in @($td['outputs'])) {
            $resolved = Resolve-Path (Join-Path $projectRoot $out) -ErrorAction SilentlyContinue
            if ($resolved) { Remove-Item $resolved -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
```

Bu değişiklik `shared_branch` bağımsız — `outputs` tanımlanmış her workflow'u etkiler.

---

### 8 — `hooks/verify/00-privacy-scan.ps1`: Diff-Only Scan (Bug Fix)

`task_mark_done` doğrulama gate'i privacy scan hook'unu `$StagedOnly = $false` ile çağırıyordu. Eski davranış tüm repo'yu tarıyordu — agent'ın yaptığı değişikliklerden bağımsız, repodaki pre-existing ihlaller task'ı bloklıyordu.

**Eski:**
```powershell
# Tüm tracked + untracked dosyalar (repo genelinde)
$trackedFiles  = git ls-files
$untrackedFiles = git ls-files --others --exclude-standard
$allFiles = @($trackedFiles) + @($untrackedFiles)
```

**Yeni:**
```powershell
# Sadece bu branch'te değişen dosyalar (merge-base'den bu yana)
$mergeBase = git merge-base HEAD origin/main
$allFiles = git diff --name-only --diff-filter=ACM "$mergeBase..HEAD"
# + untracked yeni dosyalar (henüz commit edilmemiş olabilir)
$untrackedFiles = git ls-files --others --exclude-standard
```

Base branch `origin/main → origin/master → origin/develop → main → master` sırasıyla denenir. Hiçbiri bulunamazsa `HEAD~1..HEAD` diff'ine fallback yapar.

---

### 9 — `workflow.yaml`: `shared_branch` + "Open PR" Task

```yaml
shared_branch: "feature/issue-{input.issue_number}"

tasks:
  - name: "Design Issue"
    outputs:
      - "docs/designs/issue-{input.issue_number}-*/design.md"
    ...
  - name: "Design Test Cases"
    outputs:
      - "docs/designs/issue-{input.issue_number}-*/test-cases.md"
    ...
  - name: "Implement Issue"
    depends_on: ["Design Issue", "Design Test Cases"]
    ...
  - name: "Unit Tests"
    depends_on: ["Implement Issue"]
    ...
  - name: "Integration Tests"
    depends_on: ["Implement Issue"]
    optional: true
    ...
  - name: "Open PR"          # YENİ — script task
    type: script
    script_path: "scripts/open-pr.ps1"
    depends_on: ["Unit Tests", "Integration Tests"]
```

---

### 9 — `scripts/open-pr.ps1`: PR Açma Scripti

`type: script` task olarak çalışır. Dotbot pipeline'ı bu scripti "Open PR" task'ı için çağırır.

```
1. kickstart-prompt.txt'ten issue number oku
2. workflow manifest'ten shared_branch şablonunu çöz
3. settings.default.json'dan base branch + PR label oku
4. `gh pr list --head $sharedBranch` ile mevcut PR kontrol et (idempotent)
5. Yoksa `gh pr create --title ... --body ... --base main --head feature/issue-N` çalıştır
6. `gh issue edit N --add-label needs-review` ile issue'ya label ekle
```

---

## Agent Konfigürasyonu — İki Fazlı Model

Dotbot her task'ı iki ayrı Claude invocation'ına böler:

```
Phase 1 (Analysis)  →  98-analyse-task.md  +  APPLICABLE_AGENTS persona
Phase 2 (Execution) →  numbered prompt       +  APPLICABLE_AGENTS persona
```

`workflow.yaml`'daki her task'ın `applicable_agents` listesi, `98-analyse-task.md` ve execution prompt'una `{{APPLICABLE_AGENTS}}` placeholder'ı aracılığıyla enjekte edilen agent persona dosyasını belirtir. Claude her iki fazda da aynı AGENT.md'yi okur — analysis fazında Phase 1 kurallarını, execution fazında Phase 2 kurallarını uygular.

### Task → Agent → Prompt Eşlemesi

| Task | `applicable_agents` | Analysis (Phase 1) | Execution (Phase 2) |
|---|---|---|---|
| Design Issue | `design-issue-agent` | Gap analizi yap, `task_mark_needs_input` ile kullanıcı onayı al | `10-design-issue.md` — design.md yaz, GitHub label'ları güncelle |
| Design Test Cases | `design-test-cases-agent` | 6-açılı senaryo analizi yap, `task_mark_needs_input` ile onay al | `11-design-test-cases.md` — test-cases.md yaz |
| Implement Issue | `implement-issue-agent` | Design doc'u oku, etkilenen dosyaları belirle, implementation plan üret | `12-implement-issue.md` — production kodu yaz, build'i çalıştır |
| Unit Tests | `unit-test-pr-agent` | PR diff'i oku, gap analizi yap, test planı üret | `14-unit-test-pr.md` — unit testleri yaz, çalıştır |
| Integration Tests | `integration-test-pr-agent` | test-cases.md'yi oku, test class/method skeleton'ları oluştur | `15-integration-test-pr.md` — integration testleri yaz, çalıştır |

### Phase 1 — Analysis

Her task için `98-analyse-task.md` çalışır. Agent şunları yapar:

1. Issue, design doc, CLAUDE.md, kaynak kodu okur
2. `needs_interview: true` olan task'larda `task_mark_needs_input` çağırarak kullanıcıya sorar ve cevabı bekler
3. Analysis tamamlandığında `task_mark_analysed` ile analiz objesini kaydeder — bu obje Phase 2'ye aktarılır

**`needs_interview` durumu:**

| Task | `needs_interview` | Sebep |
|---|---|---|
| Design Issue | `true` | Gap analizi tablosu kullanıcı onayı gerektirir |
| Design Test Cases | `true` | Test group önerisi kullanıcı onayı gerektirir |
| Implement Issue | `false` | Genuine ambiguity varsa opsiyonel olarak sorabilir |
| Unit Tests | `false` | Gap'ler PR comment olarak iletilir, kullanıcıya sorulmaz |
| Integration Tests | `false` | Test planı test-cases.md'den mekanik olarak türetilir |

### Phase 2 — Execution

`task_mark_analysed` sonrası `99-autonomous-task.md` execution prompt olarak çalışır, ancak `type: prompt_template` task'larda bu numbered prompt ile override edilir. Agent şunları yapar:

1. `task_get_context` ile Phase 1 analiz objesini okur
2. Execution prompt'undaki adımları takip eder
3. `task_mark_done` çağırır — verification gate (privacy scan, git-clean, git-pushed) geçilmezse bloklenir

### Agent Persona Hard Limits

Her AGENT.md iki fazın sınırlarını açıkça tanımlar:

**Phase 1 MUST NOT (design-issue-agent örneği):**
- Disk'e dosya yazma
- Git write komutları çalıştırma
- GitHub mutation API'leri çağırma (`update_issue`, `add_issue_comment`)
- `task_mark_done` çağırma

**Phase 2 MUST NOT:**
- Kullanıcıya yeni soru sorma (`task_mark_needs_input`)
- Gap analizini yeniden yapma
- Analysis objesinde olmayan kararlar uydurma

---

## Agent'lardan Kaldırılan Git İşlemleri

Tüm git operasyonları framework'e taşındı — agent'lar hiç git komutu çalıştırmıyor:

| Agent | Kaldırılan İşlem |
|---|---|
| `design-issue-agent` | `git checkout -b`, `git commit`, `git push` |
| `design-test-cases-agent` | `git commit`, `git push` |
| `implement-issue-agent` | `git checkout`, `git commit`, `git push`, `gh pr create` |
| `unit-test-pr-agent` | `git commit`, `git push` |
| `integration-test-pr-agent` | `git commit`, `git push` |

---

## Değişen Dosyalar

| Dosya | Değişiklik |
|---|---|
| `workflows/default/systems/runtime/modules/workflow-manifest.ps1` | `shared_branch` field + fallback parser |
| `workflows/default/systems/runtime/modules/WorktreeManager.psm1` | `BranchName` param + `shared_branch` map flag + orphan skip |
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1` | Manifest okuma, placeholder çözme, worktree override, commit+push, merge suppression, failure koruma |
| `workflows/default/systems/ui/server.ps1` | `rerun: fresh` sırasında outputs cleanup |
| `workflows/default/hooks/verify/00-privacy-scan.ps1` | Diff-only scan (pre-existing ihlalleri artık bloklamaması için) |
| `workflows/issue-driven/workflow.yaml` | Top-level `shared_branch`, "Open PR" task |
| `workflows/issue-driven/scripts/open-pr.ps1` | **YENİ** — PR açma scripti |
| `workflows/issue-driven/recipes/prompts/10-design-issue.md` | Git ops kaldırıldı |
| `workflows/issue-driven/recipes/prompts/11-design-test-cases.md` | Git ops kaldırıldı |
| `workflows/issue-driven/recipes/prompts/12-implement-issue.md` | Git ops + PR açma kaldırıldı |
| `workflows/issue-driven/recipes/prompts/14-unit-test-pr.md` | Git ops kaldırıldı |
| `workflows/issue-driven/recipes/prompts/15-integration-test-pr.md` | Git ops kaldırıldı |
| `workflows/issue-driven/recipes/agents/*/AGENT.md` (5 dosya) | Git ops kuralları güncellendi |

**Dokunulmayan:** `Complete-TaskWorktree`, `task_mark_done`, `WorktreeMap` lock mekanizması, analysis phase, verification hooks.

---

## Kapsam Dışı

- `{input.issue_number}` dışındaki placeholder'lar — şimdilik sadece issue number destekleniyor
- Worktree'nin otomatik temizlenmesi — PR merge edilince manuel ya da ayrı bir `cleanup` task ile yapılabilir
- Concurrent slot desteği shared branch modunda test edilmedi — issue-driven workflow tek slot varsayıyor

---

## Keşfedilen Framework Bug'ları

Bu workflow geliştirilirken dotbot core'da bulunan bug'lar. Ayrı issue'lar olarak raporlanacak.

---

### Bug 1 — `workflow-manifest.ps1` çok geç dot-source ediliyor

**Dosya:** `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1`

**Sorun:** `workflow-manifest.ps1` yalnızca ~line 388'deki task_gen recovery bloğunun içinde dot-source ediliyor. `Get-ActiveWorkflowManifest` ise ~line 120'de (main loop başlamadan önce) çağrılıyor. Dosya henüz yüklenmediği için `CommandNotFoundException` fırlatıyor:

```
The term 'Get-ActiveWorkflowManifest' is not recognized as a name of a cmdlet...
```

**Fix:** `task-reset.ps1` ve `post-script-runner.ps1` ile birlikte startup bloğuna dot-source eklendi:

```powershell
. (Join-Path $botRoot "systems\runtime\modules\workflow-manifest.ps1")
```

---

### Bug 2 — Privacy scan tüm repo'yu tarıyor, yalnızca diff'i değil

**Dosya:** `workflows/default/hooks/verify/00-privacy-scan.ps1`

**Sorun:** `task_mark_done` verification gate hook'u `$StagedOnly = $false` ile çağırıyor. Bu modda script tüm tracked + untracked dosyaları tarıyor. Agent'ın kendi diff'i tamamen temiz olsa bile repodaki önceden mevcut ihlaller (eski şifreler, test fixture'ları, helm değerleri vb.) task'ı bloklıyor. Hata mesajında hangi dosyaların agent tarafından eklendiği, hangilerinin pre-existing olduğu ayırt edilemiyor.

**Fix:** `$StagedOnly = $false` modunda artık `git diff merge-base..HEAD` ile yalnızca bu branch'te değişen dosyalar taranıyor. Base branch `origin/main → origin/master → origin/develop → main → master` sırasıyla aranıyor; bulunamazsa `HEAD~1..HEAD` diff'ine fallback yapılıyor.

---

### Bug 3 — `workflow.yaml` `env_vars` şemasında `var` yerine `name` yazılınca crash

**Dosya:** `workflows/default/systems/runtime/modules/workflow-manifest.ps1` → `New-EnvLocalScaffold`

**Sorun:** `New-EnvLocalScaffold` env var adını `var` field'ından okuyor. Workflow yazarları doğal olarak `name: GITHUB_TOKEN` yazdığında `$varName` null geliyor, `$existing.ContainsKey(null)` hatası fırlatılıyor:

```
Exception calling "ContainsKey" with "1" argument(s): "Value cannot be null. (Parameter 'key')"
```

Hata mesajı hangi field'ın eksik olduğunu göstermiyor, debug edilmesi zor.

**Fix (geçici):** `workflow.yaml`'da `var: GITHUB_TOKEN` + `name: "GitHub Personal Access Token"` şeması kullanıldı.

**Önerilen kalıcı fix:** `New-EnvLocalScaffold` içinde `name` field'ına da fallback eklenmeli (`$varName = $ev.var ?? $ev.name ?? $ev['var'] ?? $ev['name']`), ya da null kontrolü + açıklayıcı hata mesajı eklenmeli.

---

### Bug 4 — PowerShell string interpolation: `"$var: text"` syntax error

**Dosya:** `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-WorkflowProcess.ps1`

**Sorun:** `"Pushed $sharedBranch: $commitMsg"` satırında PowerShell `$sharedBranch:` ifadesini scope-qualified variable (`$env:`, `$global:` gibi) olarak parse ediyor ve compile-time syntax error fırlatıyor:

```
Variable reference is not valid. ':' was not followed by a valid variable name character.
Consider using ${} to delimit the name.
```

Layer 1 compilation testleri bunu yakalıyor.

**Fix:** `$($sharedBranch)` syntax'ı kullanıldı:

```powershell
# Önce (hatalı)
"Pushed $sharedBranch: $commitMsg"

# Sonra (doğru)
"Pushed $($sharedBranch): $($commitMsg)"
```

---

### Bug 5 — `commit-bot-state.ps1` task state JSON'larını main'e commit ediyor

**Dosya:** `workflows/default/hooks/scripts/commit-bot-state.ps1` + `workflows/default/go.ps1` (`.bot/.gitignore` kaynağı)

**Sorun:** `.bot/workspace/tasks/` altındaki task JSON dosyaları (todo, in-progress, done, analysed vb.) git tarafından tracked. `commit-bot-state.ps1` her autonomous task başlangıcında bu dosyaları main'e commit edip push ediyor. İki soruna yol açıyor:

1. **Main branch'e direkt push** — branch protection kuralları varsa fail olur; olmasa bile PR olmadan main geçmesine neden olur.
2. **Git history kirliliği** — ephemeral runtime state (her run'da sıfırlanıyor) git history'de kalıcı olarak birikiyor, anlamlı bir değeri yok.

Ayrıca script `task/` prefix'ini tanıyıp özel davranıyor ama `feature/` prefix'ini (shared branch modu) tanımıyor — feature branch'te de aynı hatalı davranışı gösteriyor.

**Mevcut `.bot/.gitignore`'da olanlar:**
```
.control/          # runtime signals — doğru ignored
state/sessions/    # session history — doğru ignored
```

**Eksik olan:**
```
workspace/tasks/   # task JSON'ları — ephemeral, ignored olmalı
```

**Önerilen fix:**
- `workflows/default/go.ps1` içinde üretilen `.bot/.gitignore`'a `workspace/tasks/` eklenmeli
- `commit-bot-state.ps1`'e `feature/` prefix kontrolü eklenmeli (shared branch modunda state commit'leri feature branch'e yapılmalı, main'e değil)

**Not:** `.bot/workspace/tasks/.gitkeep` dosyaları directory skeleton için gerekli — onlar tracked kalmalı, sadece `*.json` dosyaları ignore edilmeli:
```
workspace/tasks/**/*.json
```

---

### Bug 6 — `dotbot workflow add` komutu `scripts/` klasörünü kopyalamıyor

**Dosya:** `workflows/issue-driven/scripts/open-pr.ps1` + `dotbot workflow add` mekanizması

**Sorun:** `dotbot workflow add issue-driven` komutu workflow'un `recipes/`, `workflow.yaml`, `settings.json` gibi dosyalarını `.bot/workflows/issue-driven/` altına kopyalıyor ancak `scripts/` alt klasörünü kopyalamıyor. Bu nedenle "Open PR" task'ı çalıştırıldığında:

```
✗ Script not found: workflows/issue-driven/scripts/open-pr.ps1
  (base: C:\...\clarantis-dotbot\.bot\workflows\issue-driven)
```

**Geçici fix:** `open-pr.ps1`'i manuel olarak hedef projeye kopyalamak:
```powershell
Copy-Item "dotbot/workflows/issue-driven/scripts/open-pr.ps1" `
    ".bot/workflows/issue-driven/scripts/open-pr.ps1" -Force
```

**Önerilen fix:** `workflow add` komutunun tüm alt klasörleri (özellikle `scripts/`) kopyalaması sağlanmalı.

---

### Bug 7 — `open-pr.ps1` var olmayan theme fonksiyonlarını çağırıyor

**Dosya:** `workflows/issue-driven/scripts/open-pr.ps1`

**Sorun:** Script içinde `Write-DotbotError`, `Write-DotbotWarning`, `Write-Success`, `Write-DotbotLabel` gibi fonksiyonlar kullanılıyor ancak `DotBotTheme.psm1` modülünde bu isimler tanımlı değil. Gerçek API:

| Kullanılan (hatalı) | Doğrusu |
|---|---|
| `Write-DotbotError "msg"` | `Write-Status "msg" -Type Error` |
| `Write-DotbotWarning "msg"` | `Write-Status "msg" -Type Warn` |
| `Write-Success "msg"` | `Write-Status "msg" -Type Success` |
| `Write-DotbotLabel -Label "L" -Value "V"` | `Write-Label "L" "V" -ValueColor Amber` |

**Fix uygulandı:** `open-pr.ps1` doğru fonksiyon isimleriyle güncellendi.

---

### Bug 8 — `open-pr.ps1` var olmayan GitHub label ile PR açmaya çalışıyor

**Dosya:** `workflows/issue-driven/scripts/open-pr.ps1`

**Sorun:** `gh pr create --label needs-review` çağrısı, `needs-review` label'ı hedef repoda yoksa aşağıdaki hatayla başarısız oluyor:

```
could not add label: 'needs-review' not found
```

`gh pr create` label yoksa tamamen fail ediyor (PR açmıyor).

**Fix uygulandı:** `--label` parametresi ve issue'ya label ekleme bloğu `open-pr.ps1`'den tamamen kaldırıldı. PR açma işlemi artık label'a bağımlı değil.

---

## Session 2 — 2026-04-23 — Ek Bug'lar ve Status Güncellemeleri

### Bug 5 — Status güncellemesi

**Fix uygulandı (kısmi):** `workflows/default/.gitignore` template'ine eklendi:
```
workspace/tasks/**/*.json
!workspace/tasks/samples/**
workspace/product/interview-answers.json
workspace/decisions/**/*.json
!workspace/decisions/samples/**
```

Yeni `dotbot init`'ler `.bot/.gitignore`'da bunları alır. Mevcut projelerde tracked olan dosyalar `git rm --cached` ile index'ten çıkarıldı.

**Takip gözlemi:** clarantis-dotbot clean setup sonrası autonomous run'ında main'e yine commit düştü (`chore: save autonomous task state` — 4 dosya: 3 decision JSON + 1 interview-answers.json). Sebep code path değil, sadece gitignore eksikliğiydi. Interview/decision path'leri eklenerek giderildi.

**Kalan:** `commit-bot-state.ps1`'e `feature/` prefix kontrolü henüz eklenmedi.

---

### Bug 9 — Worktree isolation is ineffective — agent file writes land on project root, not the task branch

**Dosya:** `workflows/default/systems/runtime/ClaudeCLI/ClaudeCLI.psm1:577`

**Sorun:** Framework her task için bir git worktree oluşturuyor (`../worktrees/{repo}/task-{short-id}-{slug}/` veya shared branch modunda `.../feature-...`) ama Claude CLI process'i her zaman **project root**'ta başlatılıyor:

```powershell
# Ensure claude.exe starts in the project root so it discovers .mcp.json
if ($global:DotbotProjectRoot -and (Test-Path $global:DotbotProjectRoot)) {
    $psi.WorkingDirectory = $global:DotbotProjectRoot
}
```

Worktree path Claude process'ine hiç geçilmiyor. Sonuç: agent'ın yaptığı tüm dosya düzenlemeleri project root'ta (ana repo'nun mevcut branch'inde = main) biriktirilir. Worktree ve task branch boş kalır.

#### Reproduction (dotbot main, shared_branch kullanmadan)

1. Temiz bir test repo'da `dotbot init`. Tek satırlık bir `README.md` tracked olsun.
2. Task aç:
   ```
   dotbot task create \
     --name "Append line to README" \
     --description "Add the line 'hello from dotbot' at the end of README.md"
   ```
3. Autonomous çalıştır, Claude task'ı tamamlasın.
4. Task çalışırken (ya da `Complete-TaskWorktree` cleanup'ından önce) iki lokasyonu compare et:
   ```
   grep "hello from dotbot" ../worktrees/{repo}/task-*/README.md   # worktree
   grep "hello from dotbot" ./README.md                             # project root
   ```
5. Task tamamlandıktan sonra squash-merge commit'ini incele:
   ```
   git log main --oneline -3
   git show HEAD --stat
   ```

**Expected bug signature:**
- Adım 4: worktree README'de `hello` YOK, project root README'de `hello` VAR
- Adım 5: `README.md` main'de değişmiş görünüyor — ama task branch'i üzerinden değil, stash/pop cycle'ı üzerinden geldi (Invoke-WorkflowProcess.ps1'de main repo'nun dirty state'i merge öncesi stash'leniyor, sonrasında pop'lanıyor)

#### Saha gözlemleri

- **Vaka 1 (shared_branch, stash/pop yok):** `feat: extend Analysis Worker...` commit'i `feature/issue-1-fe154c` yerine main'e gitti. `git branch --contains aa40447` → `main`. Feature branch sıfır commit ahead of main.
- **Vaka 2 (shared_branch, clean setup):** Design Issue task "done" oldu, agent GitHub issue'ya "design complete" yorumu attı — ama `docs/designs/cs-1-analysis-worker-orchestration/design.md` worktree'ye (`feature-issue-1-bf1519`) değil, main repo'ya yazıldı. Worktree'nin `docs/designs/` listinde `cs-1-analysis-worker-orchestration/` yok; project root listinde var.

GitHub tarafındaki tool çağrıları (`gh issue comment`, MCP API çağrıları) cwd'den bağımsız olduğu için "başarılı" görünüyor — bu, local dosya yazımı ile GitHub ops arasındaki ayrık davranış bug'ı normal modda maskelemişti.

#### Etki

- **Normal mod (per-task branch):** Claude'un değişiklikleri project root'ta biter → `Complete-TaskWorktree` stash/pop cycle'ı ile main'e düşer → görünürde "çalışıyor" ama task branch'leri fiilen boş. Squash-merge commit'i stash/pop nedeniyle file diff içeriyor gibi görünür, ama task branch history'sinde Claude-origin commit yok. "Task-based isolation" iddiası karşılanmıyor.
- **Shared branch mod (issue-driven):** Stash/pop yok. Kod main'de kalır, feature branch boş. PR açılır ama içi boş. Kullanıcı görünür şekilde bozuk.

#### Önerilen Fix

1. `Invoke-ClaudeStream` (ClaudeCLI.psm1) → `-WorkingDirectory` parametresi ekle, default `$global:DotbotProjectRoot`
2. `Invoke-ProviderStream` (ProviderCLI.psm1) → aynı parametreyi passthrough
3. `Invoke-WorkflowProcess.ps1` → task execution'da (hem analysis hem execution phase) `$worktreePath` geç
4. `.mcp.json`'u worktree'ye hardlink et (Windows'ta `New-Item -ItemType HardLink`; PS 7 destekler) — MCP discovery cwd'den yapıldığı için bozulmasın

#### Doğrulama (fix sonrası)

Aynı repro adımlarını tekrar et:
- Adım 4: worktree README'de `hello` VAR olmalı
- Adım 5: squash-merge commit'i gerçek file diff içermeli
- Shared branch modda: feature branch'te gerçek commit'ler birikmeli, PR'da diff görünmeli

#### Fix uygulandı

- `Invoke-ClaudeStream` (ClaudeCLI.psm1): `-WorkingDirectory` param eklendi, default `$global:DotbotProjectRoot` (geriye uyumlu)
- `Invoke-ProviderStream` (ProviderCLI.psm1): `-WorkingDirectory` passthrough
- `Invoke-WorkflowProcess.ps1`: hem analysis hem execution phase'lerde `$worktreePath` `WorkingDirectory` olarak geçiliyor
- `WorktreeManager.psm1`: worktree `.mcp.json`'ı tracked değilse project root'tan kopyalıyor (MCP discovery için). Kickstart ve non-worktree akışlar dokunulmadı — onlar hâlâ `$global:DotbotProjectRoot`'ta çalışır.

---

### Bug 10 — `open-pr.ps1` şablondan çözüyor, gerçek run state'ten değil

**Dosya:** `workflows/issue-driven/scripts/open-pr.ps1`

**Sorun:** Script shared branch adını workflow.yaml template'inden türetiyordu (`feature/issue-{input.issue_number}` → `feature/issue-1`). Ama framework her run'a bir hex suffix ekliyor (`feature/issue-1-fe154c`). Script template adıyla PR arıyor, eski run'ın PR'ını bulunca "zaten var" deyip skip ediyor — mevcut run için PR açılmıyor.

**Fix uygulandı:** Script artık `.control/workflow-runs/{workflow}.json`'dan gerçek run'ın suffix'li branch adını okuyor:

```powershell
$runStateFile = Join-Path $controlDir "workflow-runs\$($activeWf.name).json"
if (Test-Path $runStateFile) {
    $runState = Get-Content $runStateFile -Raw | ConvertFrom-Json
    if ($runState.shared_branch) { $sharedBranch = [string]$runState.shared_branch }
}
```

---

### Bug 11 — Agent `task_mark_skipped` vs `task_mark_done` karıştırıyor

**Dosyalar:** Tüm `recipes/prompts/1{0-5}-*.md`

**Sorun:** Pre-flight skip check'lerinde ("`needs-design` label yok → skip") agent `task_mark_skipped` çağırıyor. Ama bu tool sadece framework-level non-recoverable error'lar için:

```yaml
skip_reason:
  enum: [non-recoverable, max-retries]
```

**Cascade:**
1. Task `skipped/` klasörüne gidiyor
2. Framework completion check sadece `in-progress/` ve `done/`'a bakıyor → "unexpected state" → retry
3. Retry'da worktree zaten var → `fatal: ... already used` hatası
4. 3 retry → max-retries → gerçekten skipped
5. Dependent task'lar "blocked by skipped prerequisite" deadlock

**Üç örtüşen kök neden:**
1. `task_mark_skipped` hem "not applicable" hem "error terminal" için overload
2. Completion check `skipped/` ve `cancelled/`'ı terminal kabul etmiyor
3. State machine'de `failed` state yok — `skipped` bunun rolünü de üstleniyor

**Prompt-level fix önerilmiş ve uygulanmıştı** (5 prompt'a "Use `task_mark_done` — NOT `task_mark_skipped`" uyarısı + summary metninde "Skipped —" → "No action required —" değişimi), **ancak MCP refactor rollback'iyle birlikte revert edildi**. Yeniden uygulanması gerekiyor.

**Framework-level kalıcı fix:**
- Completion check'i `skipped/` + `cancelled/` + `failed/` terminal kabul etsin
- State machine'e `failed` ekleyip `skipped`'i "intentional skip only" olarak kısıtla

---

### Bug 12 — `Get-BaseBranch` shared branch için yanlış base seçiyor

**Dosya:** `workflows/default/systems/runtime/modules/WorktreeManager.psm1:92-104`

**Sorun:**
```powershell
function Get-BaseBranch {
    $branch = git symbolic-ref --short HEAD   # current branch
    if ($branch) { return $branch }            # → returned, fallback never reached
    foreach (@('main', 'master')) { ... }
}
```

Fonksiyon her zaman ana repo'nun mevcut branch'ini döndürür. Normal task branch'leri için mantıklı — ama shared branch modunda, önceki run'dan kalma feature branch'inde HEAD varsa yeni suffix'li branch oradan dallanıyor → yeni run kendi branch'ine önceki işi kopyalıyor → "zaten yapılmış" tespiti → execution fiilen no-op.

**Önerilen fix:** 
- `New-TaskWorktree`'ye `-BaseBranch` parametresi ekle
- `Invoke-WorkflowProcess.ps1`'de shared branch modunda `issue_driven.pr_target` (default: `main`) ile override et
- Veya `Assert-OnBaseBranch` çağrısını shared branch için force-main yap

---

### Bug 13 — `dotbot init --force` mevcut `.mcp.json`'ı merge etmiyor

**Dosya:** `scripts/init-project.ps1:815-819`

**Sorun:**
```powershell
if (Test-Path $mcpJsonPath) {
    Write-DotbotWarning ".mcp.json already exists -- skipping"
} else {
    # create with dotbot + context7 + playwright
}
```

`.mcp.json` varsa HİÇBİR şey yapmıyor. Kullanıcı önceden manuel bir MCP server eklemişse (github, figma vb.) veya bir workflow kendi MCP entry'sini bıraktıysa, `dotbot init --force` dotbot entry'sini eklemiyor → "Dotbot MCP server not registered" hatası.

**Deneysel:** clarantis-dotbot reset sonrası `.mcp.json`'da sadece `github` entry kaldı (issue-driven workflow'dan). `dotbot init --force` çalıştırıldı ama `.mcp.json`'a dokunmadı. `dotbot` entry'si manuel eklemek gerekti.

**Önerilen fix:** Mevcut `.mcp.json`'ı parse et, core entry'ler (`dotbot`, `context7`, `playwright`) yoksa ekle, varsa dokunma. Diğer entry'leri (kullanıcı eklentileri) olduğu gibi koru.

**Fix uygulandı:**
- `init-project.ps1` `.mcp.json` blok'u yeniden yazıldı
- Var olan dosyada core entry'ler (dotbot/context7/playwright) yoksa ekleniyor
- Var olan core entry'ler `-Force` olmadan korunur; `-Force` ile yenilenir
- User-added entry'ler (github, figma vb.) her zaman verbatim korunur
- Invalid JSON ise actionable hata fırlatılıyor (eskiden sessiz skip'ti)

---

### Bug 14 — Agent'lar repo adını settings/skill dosyalarından tahmin ediyor, framework resolve etmiyor

**Dosyalar:**
- `workflows/default/systems/runtime/modules/prompt-builder.ps1`
- `workflows/issue-driven/recipes/prompts/{10,11,12,14,15}-*.md`
- `workflows/default/recipes/prompts/98-analyse-task.md`

**Sorun:** Agent bir issue fetch etmek için `owner/repo` bilgisine ihtiyaç duyuyor. Eski akış:
1. Agent `issue_driven.repository` setting'ini okuyor
2. Boşsa skill dosyalarındaki hardcoded `Clarantis/clarantis` string'ini kullanıyor
3. O repo yoksa ya da yanlışsa → 404 / auth error

Framework git remote'u zaten biliyor ama agent'a iletmiyordu. Proje-başına-hardcode çirkin çözümdü.

**Fix uygulandı (option 1 — prompt placeholder):**

1. `Build-TaskPrompt`'a yeni yardımcı: `Resolve-RepositoryFromGit` — `git remote get-url origin`'i parse eder (`https://github.com/owner/repo.git` ve `git@github.com:owner/repo.git` formatlarını destekler).
2. `Build-TaskPrompt`'a `-Repository` parametresi eklendi. Boşsa `Resolve-RepositoryFromGit` fallback'e düşüyor.
3. `Invoke-WorkflowProcess.ps1` hem execution hem analysis phase'lerde:
   - `settings.issue_driven.repository` varsa onu geçiriyor (explicit override)
   - Yoksa boş geçip Build-TaskPrompt'un git remote'dan çözmesine bırakıyor
4. `{{REPOSITORY}}` placeholder'ı 5 issue-driven execution prompt'u + `98-analyse-task.md`'ye eklendi:
   ```markdown
   > **Repository:** `{{REPOSITORY}}` — use this for every GitHub API / MCP call.
   > Do not guess from settings or skill files; the framework resolves this from git remote.
   ```

**Kapsam dışı (gelecek iyileştirmeler):**
- `.claude/commands/*.md` skill dosyalarındaki hardcoded repo referansları projeye özgü — framework dokunmuyor. Proje sahibi kendi skill'lerini `{{REPOSITORY}}` ile güncellemek isterse ayrı bir init-time substitution ekleyebilir.
- AGENT.md persona dosyaları Build-TaskPrompt'tan geçmiyor, placeholder çalışmaz. Agent persona dosyası içindeki repo referansları execution prompt'unun verdiği `{{REPOSITORY}}` değerini kullanacak şekilde yazılmalı.

---

## Revisit Önceliği

| Bug | Status | Öncelik | Kapsam |
|---|---|---|---|
| 9 | Fix uygulandı | — | ClaudeCLI + ProviderCLI + Invoke-WorkflowProcess + WorktreeManager (.mcp.json materialize) — clean setup test bekliyor |
| 11 | Prompt fix revert, açık | Yüksek | Hem prompt'lar hem framework completion check |
| 12 | Açık | Yüksek | WorktreeManager + Invoke-WorkflowProcess |
| 13 | Fix uygulandı | — | init-project.ps1 merge mantığı |
| 5 | Kısmi fix | Düşük | Gitignore OK, `commit-bot-state.ps1` feature/ prefix kaldı |
| 10 | Fix uygulandı | — | — |
| 14 | Fix uygulandı | — | Skill dosyaları kapsam dışı |

**Not:** Bug 9 düzelince Bug 5'in tüm yüzeysel semptomları (main'e chore commit'leri) kaybolur çünkü hepsi `commit-bot-state.ps1`'in yanlış branch'te çalışmasından kaynaklanıyor.
