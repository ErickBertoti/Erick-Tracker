# Fase 1 — planejador de treinos para Mac

## Objetivo

Entregar um aplicativo nativo de planejamento de treinos, em português brasileiro, que funcione integralmente sem conexão. O banco começa vazio: os exemplos do protótipo não representam dados pessoais e não são carregados no armazenamento do usuário.

O projeto usa SwiftUI e SwiftData, com alvo macOS 26.6. A janela abre em 1280 × 800 e tem mínimo de 1024 × 700. A interface segue as cores semânticas do sistema, acento teal e aparência Sistema/Claro/Escuro. O nome provisório é **Erick Tracker**.

## Fluxos implementados

### Início e navegação

- Início mostra quantidades reais de modelos ativos, exercícios ativos e programas, ações de criação e os seis modelos ativos editados mais recentemente.
- A barra lateral oferece Início, Treinos, Exercícios e os programas cadastrados.
- O rodapé informa o armazenamento neste Mac e permite retentar uma gravação que falhou.
- Bibliotecas usam tabelas nativas, busca na barra de ferramentas e inspetor de detalhes. O editor permite selecionar um bloco para configurar suas propriedades.

### Biblioteca de exercícios

Cadastro e edição de nome, músculo principal, secundários, equipamento, padrão de movimento, composto/isolado e notas. Somente o nome é obrigatório. Busca ignora caixa e acentos e combina palavras de campos diferentes. Filtros por grupo, equipamento e tipo; visualização separada de ativos e arquivados.

Um exercício usado em qualquer modelo, inclusive arquivado, não pode ser apagado. A interface oferece arquivá-lo, mantendo os vínculos. Após remover todas as referências, ele pode ser excluído.

### Programas e modelos de treino

Programas podem ser criados, renomeados e excluídos. A exclusão de um programa mantém seus modelos em **Modelos avulsos**. Um treino pode ser criado, renomeado, associado a um programa, duplicado, arquivado, restaurado e excluído.

Duplicar um treino copia seus blocos e séries com novos UUIDs. As referências aos exercícios da biblioteca são compartilhadas intencionalmente; as prescrições e notas do treino são independentes.

### Editor de treino

Adicionar exercícios por um seletor com busca; caso a biblioteca esteja vazia, cadastrar um exercício e adicioná-lo ao treino aberto. Reordenar blocos pelo puxador, menu contextual ou teclado. Ao arrastar, soltar na metade superior de um bloco insere antes; na metade inferior, depois. Duplicar/remover blocos e séries.

Cada bloco novo recebe **uma série de trabalho**, com repetições e carga vazias. Os padrões iniciais são descanso de 2:00, escala RIR e alvo 2. Ajustes altera os padrões aplicados a novos blocos.

| Tipo de série | Numerada | Conta séries de trabalho |
|---|---|---|
| Aquecimento | Não | Não |
| Feeder | Não | Não |
| Trabalho | Sim | Sim |
| Top set | Sim | Sim |
| Back-off | Sim | Sim |
| Drop set | Sim | Sim |

Repetições e cargas são texto: `6–8`, `12 + 10` e `15 → 10` são preservados exatamente. Esta fase não interpreta essas expressões para calcular volume em kg ou recordes. A duração estimada é apenas uma aproximação de planejamento: 40 segundos por série mais o descanso efetivo, arredondados em minutos.

Intensidade é opcional, entre 0 e 10, e aceita vírgula decimal. Trocar RIR/RPE converte os valores preenchidos por `10 − valor`, preservando campos vazios. Descanso aceita `minutos:segundos` ou segundos inteiros. Na série, campo vazio herda o descanso do bloco; `0` é um descanso explícito de zero segundos. Alterar o padrão do bloco afeta imediatamente as séries que o herdam. A ação “Usar descanso padrão em todas as séries” remove os valores individuais.

## Modelo e persistência

O esquema `TrackerSchemaV1` e `TrackerMigrationPlan` iniciam o versionamento em **1.0.0**. Todas as entidades têm UUID, `createdAt` e `updatedAt`.

| Entidade | Conteúdo e relações principais |
|---|---|
| `Program` | Nome, posição e modelos; exclusão desassocia os modelos. |
| `Exercise` | Cadastro do movimento, notas, arquivamento e referências dos blocos. |
| `WorkoutTemplate` | Nome, programa opcional, posição, notas, arquivamento e blocos. |
| `WorkoutItem` | Exercício, posição, descanso, faixa de reps, escala/alvo de intensidade, notas e séries. |
| `SetTemplate` | Posição, tipo, reps/carga/intensidade em texto, descanso opcional e nota. |

`WorkoutStore` centraliza as operações. A ordem usa posições explícitas, sem depender da ordem das relações do SwiftData. Excluir um treino remove seus blocos e séries em cascata; excluir um bloco remove suas séries. Modelos e regras importam Foundation/SwiftData, sem AppKit.

O aplicativo usa armazenamento SwiftData local, baseado em SQLite, no diretório de suporte do aplicativo. CloudKit está explicitamente desativado. Preferências de aparência e novos blocos usam UserDefaults. Não existem credenciais, dependências de rede ou dados demonstrativos no caminho de execução normal.

Campos inline salvam ao confirmar com Enter ou sair do foco; notas salvam ao sair do foco. Operações estruturais salvam imediatamente. A gravação explícita desativa o autosave do contexto, para tratar falhas de forma consistente. Em uma falha, as alterações permanecem em memória e uma faixa oferece **Tentar novamente**. Elas só estão duráveis após uma gravação bem-sucedida. Se o banco não abrir, a tela informa o erro e permite tentar novamente, preservando o arquivo existente.

## Atalhos

| Atalho | Ação |
|---|---|
| ⌘1 / ⌘2 / ⌘3 | Início / Treinos / Exercícios |
| ⌘N | Criar conforme a seção; no editor, adicionar exercício |
| ⌥⌘N | Novo treino |
| ⌘F | Buscar; no editor, abrir o seletor de exercícios |
| ⌘D | Duplicar a seleção contextual |
| ⌘⌫ | Remover/apagar a seleção contextual |
| ⌘↩ | Adicionar série ao bloco selecionado |
| ⌥⌘↑ / ⌥⌘↓ | Mover o bloco selecionado |
| ⌥⌘I | Mostrar/ocultar o inspetor |
| ⌘, | Abrir Ajustes |
| ↩ / Esc | Confirmar/cancelar folhas e seletores |

## Executar e verificar

1. Abrir `Erick-Tracker.xcodeproj` no Xcode 27.1 ou compatível.
2. Selecionar o esquema compartilhado **Erick-Tracker** e destino **My Mac**.
3. Executar com ⌘R. Para testes de domínio e persistência, usar ⌘U.

O ambiente inspecionado tem Xcode em `/Applications/Xcode.app`, mas o `xcode-select` global aponta para Command Line Tools. É possível compilar sem alterar esse ajuste:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project Erick-Tracker.xcodeproj -scheme Erick-Tracker \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/erick-tracker-build \
  CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project Erick-Tracker.xcodeproj -scheme Erick-Tracker \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/erick-tracker-build \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Em ambientes com sandbox, o processo de macros do Swift precisa poder iniciar; uma falha de `sandbox-exec` não é, por si só, um erro nos modelos.

### Verificação realizada

Compilação Debug e testes executados com Xcode 27.1 no macOS 26.6. A suíte de domínio tem 16 cenários; o teste de layout parametrizado executa mais quatro combinações (dois tamanhos × duas aparências), totalizando 20 execuções.

O teste de layout gera 12 imagens anexadas ao resultado do Xcode, usando dados apenas em memória e janelas privadas nunca exibidas. As imagens ajudam a revisar o conteúdo e a geometria, mas a captura isolada não reproduz integralmente materiais, barras nativas e todos os controles do sistema. A conferência interativa de teclado, arraste, folhas e janela real permanece pendente: o Controle de Computador do Codex não estava autorizado nesta sessão. Para conferi-la, executar o projeto com ⌘R e seguir os critérios abaixo.

### Critérios de aceite

- Banco novo sem registros em todas as cinco entidades.
- Criar exercício, programa e treino; editar séries e reabrir o arquivo mantendo IDs, vínculos, textos compostos e ordem.
- Duplicar treino/bloco/série com IDs novos e edições independentes.
- Arquivar/restaurar mantendo dados; excluir programa sem apagar modelos; impedir exclusão de exercício referenciado.
- Remover filhos sem deixar séries órfãs e normalizar posições.
- Validar herança de descanso, tipos/numeração, RIR/RPE e busca sem acentos.
- Simular falha de gravação e confirmar que a nova tentativa persiste as alterações.
- Conferir tabelas, campos, seletores, atalhos e estados vazios em 1280 × 800 e 1024 × 700, nas aparências clara e escura.

## Limites desta entrega

Esta fase planeja treinos no Mac. Execução de sessões, aplicativo para iPhone, autenticação e sincronização entram na fase 2. Nutrição, corpo, sono e gráficos entram nas fases seguintes, descritas em [ROADMAP.md](ROADMAP.md). Nenhum indicador fictício de desempenho, histórico ou sincronização é exibido.
