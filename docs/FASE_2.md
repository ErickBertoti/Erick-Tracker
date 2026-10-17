# Fase 2 — iPhone, execução offline e sincronização

## Estado da entrega

Implementação funcional em SwiftUI, com persistência SwiftData compartilhada, alvos separados para Mac, iPhone e Live Activity. O mínimo do iPhone é iOS 26.0. As APIs usadas estão disponíveis nessa versão; nenhuma função exige iOS 27. O acabamento visual específico do iPhone foi adiado por decisão do usuário em 17/10/2026.

O backend está ativo no Supabase. A validação automatizada local e dos contratos SQL foi executada. O app foi instalado no iPhone 16 com iOS 26.6.2, e o usuário confirmou cadastro, execução offline, retomada e sincronização. O histórico do Mac recebeu os valores informados. Atividade ao vivo e aviso de descanso também foram confirmados no aparelho. O alcance exato e os casos complementares ainda não verificados estão na seção de testes.

## Organização do projeto

| Pasta/alvo | Responsabilidade |
|---|---|
| `Shared/Models` | Esquemas V1/V2, modelos e regras sem AppKit |
| `Shared/Persistence` | Containers, operações de planejamento e execução |
| `Shared/Sync` | Snapshots, fila persistente, revisões e conflitos |
| `Shared/Account` | Auth, Keychain, troca de conta e importação explícita |
| `Shared/UI` | Campos confirmáveis, conta e histórico |
| `Erick-Tracker` | Planejador e histórico somente para consulta no Mac |
| `Erick-Tracker-iOS` | Abas Treinos, Histórico e Ajustes; editor da sessão |
| `ActivityShared` | Contrato do ActivityKit, compartilhado com a extensão |
| `Erick-Tracker-LiveActivity` | Tela bloqueada e Dynamic Island |
| `SharedTests` | Testes de migração, execução, disco e sincronização em ambos os alvos |
| `supabase/migrations` e `supabase/tests` | Esquema remoto e testes transacionais |

Os arquivos antigos de modelos e persistência foram movidos para `Shared`, mantendo a identidade dos tipos V1 e o módulo de origem do app Mac. Os grupos sincronizados do projeto incluem `Shared` nos dois aplicativos. Se o Xcode mostrar diagnósticos de tipos ausentes após uma alteração externa no projeto, executar Product → Build; a compilação validada inclui esses arquivos.

## Modelo local e migração

`TrackerSchemaV1` foi preservado. `TrackerSchemaV2` reutiliza os cinco modelos originais e acrescenta:

- `WorkoutSession`: prescrição original imutável, início/fim, estado, pausas, fuso, instalação de origem, notas e horários do descanso.
- `ExerciseLog`: referência escalar opcional ao exercício/modelo original, nome prescrito, exercício realizado, posição e notas.
- `SetLog`: prescrição da série e valores realizados separados, tipo, intensidade, descanso, estado e etapas.
- `SetLogSegment`: etapa com repetições inteiras opcionais e carga decimal opcional.
- `SyncRecord`, `PendingMutation`, `SyncConflict` e `SyncCursor`: baseline remoto, conteúdo local, outbox, versões em conflito e cursor de leitura.

A migração V1 → V2 é aditiva e lightweight. UUIDs, relações, datas, posições e strings existentes permanecem. O caminho padrão original do Mac continua sendo usado para abrir o legado. Há teste com um arquivo V1 real criado e reaberto em V2.

Sessões não têm relações de exclusão com os modelos da biblioteca. A prescrição é uma cópia integral serializada no início; editar ou excluir modelos/exercícios não altera o histórico. Os filhos de modelos e sessões têm exclusão em cascata apenas dentro do próprio agregado.

As cargas realizadas são decimais validadas, armazenadas como strings canônicas com ponto e até três casas decimais, para evitar arredondamento binário. A interface apresenta vírgula. `nil` representa ausência; `"0"` representa zero explícito. Expressões planejadas como `6–8`, `12 + 10` e `15 → 10` continuam strings e nunca são convertidas automaticamente em resultados.

## Fluxo do iPhone

1. Receber modelos da conta e conferir a prescrição.
2. Iniciar uma cópia local persistente, com uma sessão ativa por instalação. Se já houver uma, o app oferece retomada.
3. Registrar repetições/carga por etapa, intensidade, descanso, status e notas. Adicionar/remover séries, adicionar/substituir/reordenar exercícios afeta apenas a sessão.
4. Pausar, retomar, concluir ou cancelar. Concluir marca séries pendentes como ignoradas; cancelar preserva os registros com estado cancelado.
5. Consultar a sessão em Histórico e usar **Corrigir registro** no iPhone. O Mac apresenta o original e o realizado, sem editar a sessão nesta fase.

Campos confirmados e operações estruturais chamam o serviço de persistência. Rascunhos numéricos são confirmados ao finalizar a edição, sair da tela ou perder atividade. Erros de gravação aparecem com nova tentativa; conteúdo não salvo não é enviado.

A numeração segue as regras do planejador: aquecimento e feeder não recebem número. Uma drop set comporta várias etapas na mesma série. O descanso inicial de cada série já resolve a herança do modelo no momento de iniciar a sessão.

## Descanso, notificações e Live Activity

`restStartedAt`, `restEndsAt` e o tempo restante em pausa são persistidos; o relógio não depende de um loop em segundo plano. A interface usa componentes temporais do sistema. Confirmar uma série inicia o descanso configurado; o app permite acrescentar tempo e pular.

A extensão WidgetKit apresenta exercício, progresso e descanso na tela bloqueada e na Dynamic Island compacta, mínima e expandida. O link `ericktracker://session/<UUID>` abre a sessão correspondente. A atividade é local, sem push token, APNs ou servidor de notificações.

O app recupera uma atividade existente e encerra atividades ao concluir, cancelar ou sair da conta. Remover a atividade não remove a sessão: o descarte fica registrado localmente e o usuário pode escolher **Mostrar atividade ao vivo** novamente. Há proteção contra uma atualização assíncrona atrasada recriar a atividade depois de sair da conta.

Avisos de descanso começam desativados. A permissão é solicitada ao ativar o ajuste. O identificador estável `tracker.rest` permite cancelar/reagendar a notificação quando o descanso muda. Permissão negada não impede executar nem salvar o treino. A exibição na tela bloqueada, Dynamic Island e a entrega do aviso devem ser verificadas separadamente no aparelho.

## Conta, isolamento e dados anteriores

Supabase Swift está fixado na versão **2.55.4**, com resolução de dependências versionada no workspace do projeto. Somente a URL e a chave publishable entram no cliente; tokens ficam em `KeychainLocalStorage`. Não há `service_role`, segredo de banco ou senha no repositório.

Cada usuário possui um arquivo separado em `Application Support/ErickTracker/Accounts/<UUID>.store`, dentro do container da plataforma. Sair da conta interrompe a sincronização, encerra a atividade e abre o armazenamento de visitante. O arquivo da conta e sua fila ficam preservados para a próxima entrada. O evento inicial do SDK permite abrir a sessão em cache mesmo sem internet; chamadas remotas ainda dependem de autenticação válida.

O transporte RPC também fica vinculado ao proprietário desse arquivo. Cada pedido verifica a identidade e fixa o token correspondente antes de iniciar o HTTP. Uma mudança de conta durante um envio não pode reutilizar o adaptador compartilhado do SDK para enviar dados da conta anterior com as credenciais da nova conta. A fila da conta original continua preservada.

Os dados da fase 1 só são associados após a ação **Vincular dados locais**. A cópia preserva IDs, verifica o resultado e rejeita uma colisão com conteúdo diferente. O arquivo anterior permanece como cópia local. Depois de vinculado, ele fica oculto na área de visitante. Não há mesclagem silenciosa de contas.

Cadastro, confirmação e recuperação usam email/senha e o retorno `ericktracker://auth/callback`. Para recuperação, abrir o link no aparelho onde o pedido foi iniciado, pois o fluxo usa PKCE. Senhas são preenchidas pelo usuário no app.

## Configuração reproduzível

| Item | Valor |
|---|---|
| Projeto | Criar um projeto próprio na organização escolhida |
| Região/plano | São Paulo (`sa-east-1`), gratuito; cotação de criação mensal 0 |
| Conexão | URL e chave publishable em `Config/Local.xcconfig`, ignorado pelo Git |
| Auth | Email habilitado, confirmação habilitada, anônimo desabilitado |
| Redirect permitido | `ericktracker://auth/callback` |

Copiar `Config/Local.xcconfig.example` para `Config/Local.xcconfig` e preencher os valores do próprio ambiente. O arquivo compartilhado `Config/Build.xcconfig` carrega essa configuração opcional tanto no Debug quanto no Release. Sem conexão válida, não há cliente de rede nem restauração de autenticação, e o planejador continua local. Somente chaves publishable são aceitas. O arquivo local existente foi preservado neste Mac; detalhes operacionais e evidências pessoais ficam fora do Git.

O email padrão do Supabase tem restrições de destinatários e limite baixo de envio; para uso pessoal, usar um email autorizado na organização. Antes de disponibilizar a terceiros, configurar SMTP próprio e verificar envio, domínio e recuperação. O Site URL padrão não é uma página de produto; todos os fluxos implementados passam o redirect nativo explicitamente.

## Contrato de sincronização, versão 1

As unidades de alteração são programa, exercício, modelo completo e sessão completa. Filhos acompanham seu modelo/sessão. Isso evita sincronizar parcialmente uma série ou a prescrição.

`WorkoutStore.save()` captura os snapshots e a outbox no mesmo `ModelContext.save()` da alteração de domínio. A fila não depende de memória nem de o app continuar aberto. Antes do primeiro envio, uma mutação pode ser consolidada; após uma tentativa, seu UUID, base e payload ficam imutáveis. Edições posteriores geram outra operação.

```json
{
  "p_mutation": {
    "protocolVersion": 1,
    "mutationID": "UUID da operação",
    "kind": "program|exercise|workout|session",
    "entityID": "UUID estável",
    "baseRevision": 0,
    "payload": { "id": "UUID", "name": "..." },
    "deleted": false
  }
}
```

- `tracker_apply_mutation(p_mutation jsonb)` aplica numa transação e responde `{status, revision, payload, deleted}`. Repetir o mesmo UUID com o mesmo pedido retorna o mesmo recibo. Reusar UUID com pedido diferente é rejeitado.
- `tracker_pull_changes(p_after bigint, p_limit int)` devolve mudanças ordenadas, com `{revision, kind, entityID, payload, deleted}`. O cliente lê páginas de 100 e salva página/cursor atomicamente.
- Revisões são geradas no servidor sob um lock por usuário mantido até COMMIT. Um cursor não ultrapassa uma transação anterior ainda não confirmada. Relógios dos aparelhos não decidem conflitos.
- Operações de resposta incerta são repetidas antes de ler mudanças, inclusive se houve uma edição local posterior. Requisições novas respeitam dependências: cadastros antes de modelos; remoções de referências antes de excluir os cadastros.
- Exclusões têm tombstones e não são purgadas nesta fase. Uma edição concorrente com exclusão não recria o UUID apagado.

O Postgres guarda snapshots JSONB em `tracker_entities`, com ownership e revisões; `tracker_links` materializa referências entre agregados e impõe chaves estrangeiras por usuário. `tracker_private` guarda contador, mudanças, recibos e IDs de filhos. A unicidade dos IDs dos filhos evita compartilhar acidentalmente blocos ou séries entre agregados.

As tabelas têm RLS e permissões explícitas. Clientes autenticados podem consultar somente seus registros públicos e executar os dois RPCs; não podem gravar nas tabelas diretamente. Os wrappers públicos são invoker; implementações privadas definer derivam `auth.uid()`, usam nomes qualificados e `search_path` vazio. O privilégio é intencional para impedir que clientes contornem os recibos, revisões e invariantes. Anônimos não executam os RPCs.

Excluir um programa preserva os modelos avulsos. A remoção estrutural de `programID`, isolada de outras mudanças remotas, pode ser rebaseada sem descartar uma edição local do modelo. Excluir um exercício ainda usado gera conflito e oferece arquivamento. Se um exercício foi excluído offline enquanto outro aparelho criou um treino que o usa, as duas decisões ficam preservadas para resolução; o app não perde a referência nem bloqueia permanentemente a leitura da fila. Aceitar uma exclusão remota de exercício ainda usado localmente exige resolver antes os treinos afetados.

Conflitos guardam ambas as versões. O usuário pode escolher o dispositivo ou a nuvem; para treinos, **manter ambas** cria novos IDs no modelo, blocos e séries, preservando referências à biblioteca. Uma exclusão remota é respeitada; preservar um treino excluído usa outra identidade. Alterações feitas enquanto o conflito está aberto atualizam sua versão local.

Disparos: após gravações (debounce de 600 ms), abertura/retomada, recuperação de conexão, ação manual e a cada 30 segundos em primeiro plano. Não há promessa de sincronização contínua em segundo plano. O Mac pode permanecer desligado durante todo o treino.

## Executar e instalar

1. Abrir `Erick-Tracker.xcodeproj` no Xcode 27.1 ou versão compatível com os SDKs usados e configurar `Config/Local.xcconfig` conforme o README.
2. No Mac, executar o esquema compartilhado **Erick-Tracker**.
3. No iPhone, executar **Erick-Tracker-iOS**; a dependência incorpora a extensão **Erick-Tracker-LiveActivity**. Há também esquema compartilhado da extensão, que compila ambos e inicia o aplicativo contêiner para criar a atividade.
4. Preencher `TRACKER_DEVELOPMENT_TEAM` no arquivo local, usando a mesma equipe para app e extensão. A equipe pessoal não é versionada.
5. Parear o iPhone, confiar no Mac e habilitar Modo de Desenvolvedor. O dispositivo usado nesta entrega é iPhone 16 com iOS 26.6.2.
6. Entrar na mesma conta Supabase nos dois apps, confirmar o email e vincular os dados antigos explicitamente no Mac.

Bundle IDs: `Erickbertoti.Erick-Tracker`, `Erickbertoti.Erick-Tracker.iOS` e `Erickbertoti.Erick-Tracker.iOS.LiveActivity`. A instalação pessoal está sujeita às restrições e à renovação periódica do provisionamento gratuito. TestFlight requer adesão apropriada ao Apple Developer Program e dispensa Modo de Desenvolvedor.

Ativar o Modo de Desenvolvedor permite executar builds de desenvolvimento e expõe ferramentas de teste a computadores autorizados/pareados. A assinatura de código e o isolamento dos apps continuam. O usuário deve confiar no código instalado e no Mac pareado. Desativar impede executar os apps instalados pelo Xcode até ativar novamente. [Apple: Modo de Desenvolvedor](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

### Backend reproduzível

As migrações foram aplicadas no projeto remoto e versionadas com os mesmos identificadores. Para outro ambiente, usar a CLI oficial (`npx supabase`) para iniciar o ambiente local ou vincular explicitamente o projeto desejado e aplicar as migrações. Nunca executar reset no projeto pessoal para testar.

Com Docker e CLI configurados, `supabase start` / `supabase db reset` criam um ambiente local vazio. O arquivo `supabase/tests/sync_protocol.sql` é um script com assertions em transação, executável com `psql -v ON_ERROR_STOP=1 -f ...`; termina em rollback e não deixa contas ou dados de teste. O app usa o projeto configurado localmente; a stack local não foi usada como dependência na validação original.

## Testes e limites verificados

- **Mac:** build e suíte completa passaram, com 31 definições de teste em 3 suítes (incluindo 4 combinações de tamanho/aparência no teste de renderização).
- **iOS 27, simulador:** build do app/extensão e os 9 testes compartilhados iniciais passaram. Dois testes de interface passaram: registro, encerramento/reabertura, retomada dos valores/descanso, conclusão, ajustes e orientação horizontal. Uma execução posterior ampliada foi interrompida a pedido do usuário para desligar o simulador e reduzir consumo do Mac.
- **Domínio:** V1 → V2 no disco; histórico imutável; texto planejado composto; nil/zero; validação numérica; pausa/descanso; uma sessão por instalação; reabertura; isolamento de arquivos de contas; novos IDs na cópia de conflito; falha de disco não envia dados.
- **Sincronização simulada:** resposta perdida; resposta perdida com nova edição; duas cópias trocando sessão e correção; conflito e manter ambas; exclusão local/remota de programa sem perder a edição offline; exclusão offline de exercício simultânea à criação remota de treino, resolvida por arquivamento sem perder referências.
- **Postgres real:** repetição idempotente, CAS, tombstone, proibição de recriação silenciosa, duas identidades isoladas por RLS/changefeed, bloqueio de gravação direta/execução anônima, referências entre agregados, proteção de exercício utilizado, remoção de programa preservando textos, proibição de referências entre usuários e compartilhamento de IDs de filhos, prescrição histórica imutável. Todos em transação revertida.
- **Transporte autenticado:** teste de troca de conta durante uma requisição HTTP; o envio já iniciado conserva o token da origem e a tentativa seguinte é bloqueada antes da rede se a identidade mudou.
- **iPhone físico 16 / iOS 26.6.2:** build assinado e instalado, assinatura verificada e app aberto com as três abas. O usuário criou/confirmou a conta no iPhone e entrou também no Mac. O Mac conectou e mostrou estado sincronizado. Um exercício e um treino identificados como teste foram criados pela interface do Mac e recebidos no iPhone. O usuário confirmou a execução offline, encerramento/reabertura, retomada, conclusão/correção e sincronização com o app Mac encerrado. O registro recebido na nuvem contém os valores que ele confirmou ter digitado (1 repetição e 900 kg). Ao reabrir o Mac, o histórico apresentou exatamente esses valores, intensidade, nota, duração e prescrição composta original. Cada execução tem seu próprio UUID e horário de início; os testes iniciados separadamente não são duplicatas por sincronização. A atualização final substituiu a mesma instalação, preservando conta e registros.
- **Atividade e aviso no aparelho:** após a atualização final, o usuário ativou os avisos, registrou uma série, bloqueou o iPhone e confirmou que apareceram a atividade ao vivo e o aviso de término do descanso. A compilação final instalada usou `ENABLE_DEBUG_DYLIB=NO`, reduzindo as assinaturas aos dois bundles; previews continuam disponíveis na configuração padrão do projeto.
- **Advisors Supabase:** segurança e desempenho sem avisos após as migrações.

Permanecem verificações humanas no aparelho: recuperação de senha, troca e expiração de autenticação na interface, execução real com duas etapas e cargas decimais (o teste físico usou valores diferentes do roteiro), teste com o Mac efetivamente desligado, entrega de notificação com processo encerrado (a confirmação foi com tela bloqueada), todos os modos da Dynamic Island, descarte/expiração da atividade pelo sistema, VoiceOver e tamanhos grandes de texto. Duas etapas, carga decimal e correção foram verificadas nos testes de domínio/persistência. O Device Hub não conseguiu espelhar a tela nesta sessão; os resultados visuais físicos foram informados pelo usuário, sem inferir o estado da tela.

Evidências de configuração e histórico foram preservadas somente no ambiente local, fora do repositório público. Os registros usados eram de teste, não representam treino realizado nem recomendação de carga.

O download adicional do runtime iOS 26.0 foi interrompido a pedido do usuário; a validação da família iOS 26 usa o aparelho físico 26.6.2. O simulador foi desligado. Acabamento visual do iPhone e aproximação do design do Mac ficam para uma rodada posterior, sem bloquear as regras e a persistência da fase 2.

## Aceite entre dispositivos

Na mesma conta: planejar no Mac → sincronizar → receber no iPhone → desligar o Mac → ativar modo avião → iniciar e registrar várias etapas → encerrar/reabrir → concluir → corrigir um resultado → reconectar → sincronizar → abrir o Mac. Conferir UUID e quantidade da sessão, tipos, etapas, reps, cargas, notas, duração e prescrição original. Repetir sincronização e confirmar ausência de duplicatas.

## Referências

- [Supabase Swift](https://supabase.com/docs/reference/swift/introduction)
- [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Auth e redirects](https://supabase.com/docs/guides/auth/redirect-urls)
- [Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Notificações locais](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [Assinaturas Apple](https://developer.apple.com/support/compare-memberships/)
