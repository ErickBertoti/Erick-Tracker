# Erick Tracker

Planejador de treinos para macOS e execução no iPhone, feito em SwiftUI. Cada dispositivo salva os dados localmente com SwiftData; a sincronização opcional usa Supabase Auth e PostgreSQL, sem depender de o Mac estar ligado.

O projeto está em desenvolvimento, em português brasileiro. O Mac cria programas, exercícios e modelos; o iPhone registra séries, retoma sessões offline e permite corrigir o histórico. Descansos têm Live Activity, Dynamic Island e aviso local opcional.

A fase 3 acrescenta Progresso nos dois apps, com peso, medidas, composição corporal e sono manuais, perfil opcional, histórico e gráficos. O fluxo funcional principal foi validado no Mac e no iPhone; os resultados e as verificações complementares estão documentados na fase.

## Executar

1. Abrir `Erick-Tracker.xcodeproj` em uma versão do Xcode compatível com os SDKs do projeto (validado com Xcode 27.1).
2. Executar o esquema **Erick-Tracker** para Mac ou **Erick-Tracker-iOS** para iPhone. Os mínimos atuais são macOS 26.6 e iOS 26.0.
3. Para conta e sincronização, copiar `Config/Local.xcconfig.example` para `Config/Local.xcconfig` e preencher URL e chave **publishable** de um projeto Supabase próprio. O arquivo local é ignorado pelo Git. Sem configuração, o planejador local permanece disponível e o app não inicia conexões com o backend.
4. Para instalar no iPhone físico, preencher `TRACKER_DEVELOPMENT_TEAM` no mesmo arquivo e escolher os identificadores de bundle apropriados à sua equipe para o app e a extensão. Parear o aparelho e habilitar Modo de Desenvolvedor.

A escrita da URL em `.xcconfig` precisa preservar `//`: `https:/$()/your-project.supabase.co`. Não usar chaves secretas, `service_role`, senha do banco ou tokens de usuário no cliente. A chave publishable é distribuída no aplicativo; a proteção dos dados depende de autenticação, RLS e das permissões das RPCs. [Chaves de API do Supabase](https://supabase.com/docs/guides/api/api-keys).

As migrações e os testes do backend estão em `supabase/`. Aplicá-los somente no ambiente escolhido; configurar email/senha, confirmação de email e redirect exato `ericktracker://auth/callback`. Para envio a terceiros, configurar SMTP próprio. Cada pessoa que clonar o projeto deve usar seu próprio backend. Credenciais de conta ficam no Keychain; bancos locais, material de assinatura e arquivos pessoais ficam fora do repositório.

## Estado e roteiro

| Fase | Entrega | Estado |
|---|---|---|
| 1 | Planejador local para Mac | Implementada |
| 2 | iPhone, execução offline, sincronização e Live Activity | Implementada; verificações complementares documentadas |
| 3 | Corpo e sono | Implementada; fluxo principal validado no Mac e no iPhone |
| 4 | Nutrição | Planejada |
| 5 | Progresso e painel completo | Planejada |
| 6 | Importação, exportação, Saúde, acessibilidade e distribuição | Planejada |

Depois das fases 3–6 haverá um patch exclusivamente visual para o mobile, com base no material do Claude Design. Ele será aplicado sobre as funcionalidades concluídas, preservando os contratos de dados e sincronização.

Detalhes, critérios e limites de validação: [Fase 1](docs/FASE_1.md), [Fase 2](docs/FASE_2.md), [Fase 3](docs/FASE_3.md) e [Roadmap](docs/ROADMAP.md). O app começa vazio; dados de demonstração existem apenas em previews e testes.

## Testes

No Xcode, usar Product → Test no esquema do Mac ou do iPhone. Os testes cobrem regras de domínio, persistência, migração e protocolo de sincronização. Os esquemas isolam a autenticação e usam armazenamento de teste; previews também não acessam a conta real. `supabase/tests/sync_protocol.sql` e `supabase/tests/progress_protocol.sql` executam assertions em transações revertidas, com identidades fictícias. As verificações físicas e os casos ainda pendentes estão descritos na documentação das fases 2 e 3.
