# PROJECT

## milestone ativa
M1, baseline de governança GSD Ralph e hardening de subcontainers, com foco em rename, remoção e isolamento real de repositório por subpasta.

## objetivo
Garantir execução incremental segura no repositório send_folder_to_github com critérios verificáveis, incluindo recuperação de metadados git quebrados e prevenção de operação acidental no repo pai.

## dependências
1. PRD ativo em `.context/prd_ralph/prd.json`.
2. Story única por ciclo no Ralph.
3. Evidência técnica por comandos shell e saída observável.
4. `create_and_push_repo.sh` precisa tratar fallback de rename por gitdir, evitar limpeza indevida em rename manual e validar que cada subcontainer é um repo isolado antes de branch/remote/push.