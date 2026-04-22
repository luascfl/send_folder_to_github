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
  - merge do fluxo `verify_parent_topics` no próprio `create_and_push_repo.sh` via ação `verify-parent-topics`, com aplicação automática de tag por padrão (e `--no-fix` para modo só auditoria).
  - remoção do arquivo externo `verify_parent_topics.sh` e da propagação recursiva desse arquivo para subrepos.
- Harness local controlado confirmou:
  - rename manual com gitdir legado não entra em `__SUBCONTAINERS_TO_CLEAR` (`RENAME_CLEAR=0`);
  - pasta removida sem rename entra em limpeza (`DELETE_CLEAR=1`);
  - recuperação de gitdir quebrado recria repo isolado da subpasta (`ISOLATED_GIT_DIR=ok`, `ISOLATED_CHECK=ok`).
- `./create_and_push_repo.sh verify-parent-topics /home/lucas/Downloads` executado com saída observável; houve `HTTP_401 Bad credentials` (token atual inválido para API), confirmando que o comando integrado está ativo e consultando a API.