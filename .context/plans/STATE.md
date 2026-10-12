# STATE

- phase: E (execution)
- milestone: M1 baseline + hardening rename/remove
- active_story: US-SFG-003
- status: in_progress

## dependências abertas
- Validar decisão para `tmp_campanha_vp` que está referenciado como subcontainer mas não existe como repositório remoto.
- Decidir tratamento dos órfãos `tmp_*` fora do mapa `.subcontainers` (fixar topic parent ou excluir).

## evidências já coletadas
- Estrutura `.context` criada no diretório alvo.
- PRD bootstrap criado em `.context/prd_ralph/prd.json` e aceito pelo `ralph build`.
- `bash -n create_and_push_repo.sh` passou após merge do verificador para dentro do script principal.
- `create_and_push_repo.sh` atualizado com:
  - fallback de rename por gitdir legado (`detect_previous_subdir_from_gitdir`);
  - recuperação de gitdir quebrado (`repair_submodule_gitdir_if_needed`);
  - proteção contra limpeza indevida em rename manual (`renamed_previous` em `prepare_subcontainer_plan`);
  - validação de repositório isolado por subcontainer (`is_subcontainer_git_repo_ready`) para impedir falso positivo de `rev-parse --is-inside-work-tree` no repo pai.
  - merge do fluxo `verify_parent_topics` no próprio `create_and_push_repo.sh` como etapa automática dos fluxos existentes (`push-subfolders`, `push-subfolders-releases` e `push-recursive`), sem ação/flag dedicada;
  - remoção do arquivo externo `verify_parent_topics.sh` e da propagação recursiva desse arquivo para subrepos.
- Harness local controlado confirmou:
  - rename manual com gitdir legado não entra em `__SUBCONTAINERS_TO_CLEAR` (`RENAME_CLEAR=0`);
  - pasta removida sem rename entra em limpeza (`DELETE_CLEAR=1`);
  - recuperação de gitdir quebrado recria repo isolado da subpasta (`ISOLATED_GIT_DIR=ok`, `ISOLATED_CHECK=ok`).
- `./create_and_push_repo.sh verify-parent-topics` agora retorna `Unknown action`, comprovando remoção da flag dedicada.
- O script passou a chamar `run_parent_topic_verifier_auto` automaticamente dentro dos fluxos existentes de push que envolvem codex.

## hardening 2026-10-11
- `delete_remote_repo` so apaga no GitHub com `ALLOW_REMOTE_DELETE=1` (antes apagava o repo cujo nome de pasta estivesse na lista de ignorados, como build, go, logs, cache).
- Varredura de segredo no conteudo em stage (`scan_staged_for_secrets`, `SECRET_SCAN=0` desliga) antes do commit; arquivo suspeito fica fora do commit, os demais seguem. Padroes de nome novos: `*.key`, `*.pfx`, `*.ppk`.
- Reescrita de historico por segredo faz backup em `.git/pre-secret-cleanup-*.bundle` e usa `--force-with-lease` com o SHA remoto anterior (antes `--force`); `SECRET_FIX_MAX_RETRIES` agora limita as tentativas (antes era ignorado e a recursao nao tinha teto).
- `commit_submodule_safely` nunca faz `--amend` (podia reescrever commit ja publicado); pull --rebase de submodule que falha e abortado em vez de deixar rebase em andamento.
- `.git` inutilizavel de subpasta e movido para `.git/broken-gitdirs/` em vez de `rm -rf`; backups `*.local-backup-*` nao sao mais apagados (ficam no disco, fora do commit).
- `curl` com timeout (`CURL_CONNECT_TIMEOUT`, `CURL_MAX_TIME`) e token fora da linha de comando; `web-ext` so e exigido na submissao ao AMO; log do rebase via `mktemp`.
- Testado em sandbox com remoto local que rejeita segredos (GH013): historico reescrito, bundle verificado, lease obsoleto recusado.

## pull-recursive 2026-10-11
- Nova acao `create_and_push_repo.sh pull-recursive` (rodar na pasta alvo, ex. `~/Downloads`): espelha os repos do GitHub. Hubs (topic `hub`) e `codex_*` vao primeiro; filhos sao os repos com topic `parent-<hub>` ou listados no `.subcontainers` do hub (le pela API quando o hub ainda nao existe no disco); hubs aninhados recursam (`PULL_MAX_DEPTH`, padrao 4). Depois os demais repos.
- Repo ja existente em qualquer subpasta (achado pela URL do origin, nao pelo nome da pasta) so recebe `fetch` e `merge --ff-only`. Nada de reset, stash ou sobrescrita: HEAD destacado, divergencia, mudanca local conflitante e pasta sem `.git` sao so reportados.
- Filho ausente declarado em `.gitmodules` entra por `submodule update --init` e volta para o branch quando e fast-forward; senao e clonado na pasta do hub.
- `PULL_DRY_RUN=1` mostra o plano sem alterar nada.
- Correcoes do pull-recursive: o destino esperado (`<hub>/<filho>/.git`) vale antes de qualquer copia achada em outro lugar, e o scan guarda o caminho mais raso por repo; o `.subcontainers` de cada hub e lido pela API (mais a copia local) antes da fase 1, entao filhos de hubs nao `codex_*` e hubs aninhados nunca viram clone de nivel superior; fetch, clone e leitura do `.subcontainers` repetem ate 3 vezes em erro de rede.

## token unico 2026-10-11
- O token do GitHub existe so em `~/Downloads/send_folder_to_github/GITHUB_TOKEN.txt` (modo 600, ignorado pelo Git). `CENTRAL_GITHUB_TOKEN_FILE` = pasta do `CANONICAL_SCRIPT` + `GITHUB_TOKEN.txt` (override: `GITHUB_TOKEN_FILE`); `reauth` grava nesse arquivo. Credenciais do AMO continuam em `~/.config/send_folder_to_github/`.
- Removidas as copias (31 arquivos): `~/.config/send_folder_to_github/GITHUB_TOKEN.txt`, 18 dentro de repos de `~/Downloads`, 12 na lixeira; e o `~/.git-credentials`, que guardava um segundo token valido de escopo menor. O `git` https agora usa `credential.https://github.com.helper` global, que le o arquivo unico.
- Cuidado: este repo e publico. O arquivo e ignorado pelo `.gitignore` e filtrado pelo script (`purge_sensitive_paths_from_index`), e a varredura de segredo cobre `ghp_`. Nao use `git add -f`.
