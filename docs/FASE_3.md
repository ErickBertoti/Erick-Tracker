# Fase 3 — corpo e sono

## Estado e objetivo

**Planejada, sem implementação iniciada.** Próxima entrega após o planejador Mac e a execução/sincronização do iPhone. Acrescentar registro manual de corpo e sono nos dois aparelhos, com persistência offline, histórico editável e gráficos derivados dos registros existentes.

Faltam quatro fases funcionais no roteiro: **3 — corpo e sono; 4 — nutrição; 5 — progresso e painel completo; 6 — dados, integrações e distribuição**. Depois delas será aplicado o patch exclusivamente visual do mobile, com o material do Claude Design. A fase 3 usa componentes nativos e o estilo atual; não antecipa esse redesenho.

O handoff local é referência de comportamento. As decisões deste documento seguem as escolhas confirmadas na conversa: SwiftUI, SwiftData e Supabase, português brasileiro e dados iniciais vazios. Dados de demonstração ficam apenas em testes/previews. O plano não altera o backend, nem solicita permissões do Saúde.

## Escopo funcional

- Perfil opcional: altura em cm, nascimento e notas. Não exigir preenchimento para usar treinos ou registrar sono.
- Registro de peso com data/hora e notas; permitir mais de uma pesagem no mesmo dia, preservando todas.
- Medidas corporais e composição com campos adicionados sob demanda, sem preencher ausências com zero.
- Método de composição explícito: bioimpedância, DEXA, dobras cutâneas, outro ou não informado. “Outro” permite descrever o método; não inferir uma técnica pelo valor.
- Sono manual com datas/horários completos de início e fim, despertares opcionais, qualidade opcional e notas.
- Criar, consultar, editar e apagar registros tanto no Mac quanto no iPhone. Exclusões sincronizam por tombstone e exigem confirmação.
- Gráficos, médias e variações com as regras abaixo. Permitir consultar o registro que originou cada ponto.
- Reutilizar conta, isolamento por usuário, fila persistente e resolução explícita de conflitos da fase 2.

Ficam para as fases seguintes: Saúde/HealthKit, importação de balanças ou CSV, sono automático, fotos corporais, nutrição, análise de desempenho e painel completo de treino. Não haverá diagnóstico, pontuação de saúde, metas clínicas ou inferência de relação entre sono e treino.

## Modelo local — SwiftData V3

Manter V1 e V2 intactos e acrescentar `TrackerSchemaV3`, reutilizando seus tipos anteriores e adicionando as entidades abaixo. Atualizar `TrackerMigrationPlan` com V2 → V3; testar também o caminho V1 → V2 → V3. Não apagar/recriar containers para migrar. Arquivos por conta e bases locais anteriores permanecem separados.

| Entidade | Campos principais | Unidade de sincronização |
|---|---|---|
| `BodyProfile` | UUID estável de perfil, altura opcional, nascimento opcional como data civil, notas, criação/alteração | Perfil completo |
| `BodyRecord` | UUID, data/hora da medição, fuso IANA registrado, origem manual, método/descrição opcionais, notas, criação/alteração | Registro completo com seus valores |
| `BodyValue` | UUID, tipo de métrica, unidade explícita, valor decimal canônico, posição; relacionamento com `BodyRecord` | Filho do registro corporal |
| `SleepRecord` | UUID, início/fim absolutos, fusos de início/fim, data civil de acordar, despertares/qualidade opcionais, notas, origem manual, criação/alteração | Registro de sono completo |

Um perfil por conta usa identidade canônica compartilhada entre aparelhos. Limpar o perfil limpa seus campos, mantendo a identidade; não criar tombstones que impeçam preenchê-lo depois. Nascimento é uma data sem horário/fuso. A altura atual não reescreve registros corporais anteriores.

`BodyValue` pertence a um único `BodyRecord`, com exclusão em cascata e no máximo um valor por métrica naquele registro. IDs dos filhos são únicos e validados também no servidor. Não duplicar um registro apenas para cada campo preenchido. A unidade integra o contrato, mesmo quando é fixa para a métrica.

### Métricas e validação

| Métrica | Unidade |
|---|---|
| Peso | kg |
| Gordura corporal | % |
| Massa de gordura | kg |
| Massa muscular esquelética | kg |
| Massa muscular | kg |
| Massa muscular percentual | % |
| Massa magra | kg |
| Cintura, abdômen, peitoral, quadril, braço, antebraço, coxa, panturrilha e pescoço | cm |

Massa muscular esquelética, muscular, magra e de gordura são métricas distintas. Não calcular uma a partir de outra nem misturar kg e %. Lateralidade de membros fica para evolução posterior; não inventar esquerda/direita em dados sem essa informação.

Entrada aceita vírgula decimal em pt-BR. Persistir valores decimais canônicos como texto, seguindo o precedente das cargas realizadas, e usar `Decimal` nas regras de cálculo. Formatar somente ao apresentar. Rejeitar texto composto, NaN/infinito, negativos e incompatibilidade de unidade. Peso, altura e circunferências exigem valor positivo; percentuais aceitam de 0 a 100; outras massas aceitam zero explícito. Campo vazio é ausência, e remover o último valor impede salvar um registro corporal vazio.

Composição exige escolha explícita do método, inclusive “não informado” quando desconhecido. Peso/medidas isolados não exigem método. Guardar o método no evento original, para que edições de perfil não alterem seu contexto.

### Sono, datas e duplicatas

- Início e fim são instantes absolutos; a duração é `fim − início`, nunca um campo editável nem diferença de relógios locais.
- Exibir data e horário nos formulários, inclusive na virada de dia. Validar fim posterior ao início. Datas longas ou corrigidas continuam visíveis antes da confirmação.
- A noite é identificada pela data de acordar no fuso de término registrado. Trocar o fuso do aparelho não muda a data histórica. Manter os dois fusos para viagens e transições de horário de verão.
- Despertares: inteiro não negativo, com `nil` diferente de 0. Qualidade: ruim, regular, boa ou ótima, sem seleção inicial e com opção de limpar.
- Nesta fase, registrar uma noite principal por data de acordar; cochilos ficam fora do fluxo. Ao tentar registrar a mesma noite, oferecer editar o registro existente.
- Uma criação simultânea da mesma noite em dois aparelhos deve preservar ambos os candidatos em conflito, sem contar duas noites nem escolher pelo relógio. A unicidade por usuário/data será verificada no servidor sob o lock já existente; a resposta de conflito identificará os dois registros. O usuário escolhe o que manter antes de incluir essa noite nas médias. Uma mudança de data também passa por essa validação.

## Médias e gráficos

Regras implementadas em funções puras, com calendário/fuso e data de referência injetados nos testes. Janela de 7 dias inclui o dia de referência e os 6 anteriores; 30 dias inclui o dia e os 29 anteriores. Não preencher dias sem registro, nem tratar opcionais como zero. O período visível filtra pontos; cada média móvel usa sua própria janela completa, inclusive os dias anteriores ao primeiro ponto visível.

| Indicador | Requisito e cálculo |
|---|---|
| Peso em 7 dias | Pelo menos 3 pesagens válidas na janela; média aritmética de todos os registros, com contagem visível. Várias pesagens no mesmo dia permanecem amostras distintas. |
| Duração de sono em 7 dias | Pelo menos 4 noites válidas distintas na janela; média da duração por noite. |
| Duração de sono em 30 dias | Pelo menos 12 noites válidas distintas na janela. |
| Horário médio de dormir/acordar | Pelo menos 7 noites válidas no período selecionado; média circular de horários locais, evitando que 23h e 1h produzam meio-dia. Exibir o período e respeitar os fusos guardados; não misturar grupos de fusos diferentes sem identificá-los. |
| Média de despertares | Pelo menos 5 noites com o campo preenchido no período; zero conta, ausência não. |
| Composição/medidas | Último e anterior do mesmo tipo/unidade; composição compara métodos iguais, sem interpolar ou unir técnicas diferentes numa tendência única. |

Se os dados não atingirem o mínimo, uma frase curta explica a quantidade necessária. Nenhum cartão de métrica ausente é criado. Com tudo vazio, mostrar somente um convite para começar a registrar. Variações usam sinal +/− e cor neutra; sem avaliação de melhora/piora por vermelho/verde.

Swift Charts: pontos de peso e linha de média, barras de duração e faixa dormir → acordar; inspeção por toque/ponteiro e alternativa textual acessível. Períodos: 7, 30 e 90 dias, 1 ano e tudo. Séries esparsas mantêm lacunas. Horários próximos à meia-noite devem aparecer em um eixo contínuo adequado à noite. Duração de sono recebe a legenda “Registro pessoal”; referências gráficas não serão apresentadas como recomendações médicas.

## Interface em SwiftUI

### Mac

- Acrescentar **Progresso** na barra lateral, sem destinos separados para corpo e sono. Usar seletor **Visão geral / Corpo / Sono**; Desempenho será introduzido na fase 5.
- Visão geral com seções condicionais de corpo e sono. O painel completo e as comparações com treino continuam na fase 5.
- Corpo: gráfico de peso, linhas das métricas existentes e histórico com edição/exclusão. Perfil em formulário acessível a partir dessa área.
- Sono: registro rápido com datas completas disponíveis, gráfico de duração/horários e histórico.
- Menu **+** e ⌘N contextual para peso, medidas, composição ou sono; folhas com Salvar/Cancelar, retorno para salvar e Escape para cancelar.
- Reutilizar janela mínima, cores semânticas, acento teal e aparência Sistema/Claro/Escuro.

### iPhone

- Acrescentar uma aba nativa **Progresso**, preservando Treinos, Histórico e Ajustes. Internamente: Visão geral, Corpo e Sono.
- Ações rápidas de registro por menu **+**; formulários em folhas com confirmação explícita. Campos numéricos com unidade visível e fechamento acessível do teclado.
- Peso, medidas e sono podem ser registrados/alterados offline nos dois aparelhos. Não há dependência do planejador Mac para esse domínio.
- Gráficos se adaptam ao Dynamic Type e oferecem a mesma informação em texto. Manter os componentes nativos atuais; o patch visual posterior poderá mudar sua apresentação.

Formulários usam rascunhos separados do modelo persistido. Salvar valida e grava domínio + outbox na mesma transação; Cancelar não modifica o histórico. Ao perder atividade, guardar o rascunho localmente para recuperação sem publicar um registro incompleto. Erros de gravação mantêm o rascunho e oferecem nova tentativa. Não apresentar “sincronizado” antes da confirmação real do servidor.

## Serviços, sincronização e compatibilidade

1. Criar `BodyStore` e `SleepStore` sobre o mesmo `ModelContext`/save transacional de `WorkoutStore`; extrair uma pequena camada comum se necessário, preservando os testes atuais. As regras não dependem de AppKit/UIKit.
2. Adicionar snapshots `BodyProfileSnapshot`, `BodyRecordSnapshot` (incluindo valores) e `SleepSnapshot`; estender captura, aplicação, canonização, importação explícita e comparação de conflitos.
3. Introduzir tipos de entidade `bodyProfile`, `bodyRecord` e `sleep` no novo protocolo. Não exigir um nome artificial de treino para validar esses payloads: o SQL atual exige `name` em todos os agregados e precisa de validação específica por tipo.
4. Criar nova migração SQL pela CLI, preservando migrações anteriores. Estender tipos aceitos, validações de valores/unidades/método/datas, identidade do perfil, unicidade de noite e registro dos IDs dos filhos. Manter RLS, ownership, permissões explícitas, recibos e revisões serializadas por usuário.
5. Registros de corpo/sono não fazem referências a modelos de treino; apagar exercício, treino ou programa não os modifica. Dados de contas diferentes permanecem isolados inclusive nos gráficos, rascunhos e conflitos.

### Evitar quebrar instalações da fase 2

O `EntityKind` e o pull atuais aceitam somente quatro tipos. Acrescentar tipos diretamente à resposta antiga faria um app anterior falhar ao decodificar a página inteira. A implantação precisa tratar isso antes de gravar dados da fase 3:

- Preservar os endpoints atuais para o contrato v1 e filtrar seu feed aos quatro tipos originais. Revisões globais podem ter lacunas; manter ordenação/paginação pela revisão efetiva de cada alteração retornada.
- Criar endpoints v2 para os três tipos novos e os tipos anteriores, reutilizando a mesma serialização de revisão e os recibos por usuário. O endpoint de escrita v2 aceita reenvios v1 já existentes e valida novos pedidos pelo protocolo correspondente.
- A fila atual não guarda `protocolVersion` por mutação. V3 deve preservá-lo: atribuir v1 às entradas migradas e v2 às novas. Nunca reescrever UUID, payload, base ou versão de uma operação que possa ter sido enviada.
- Criar cursor separado `changes-v2`, inicialmente zero, para recuperar entidades novas anteriores ao cursor v1. Reaplicar o feed idempotentemente, respeitando `serverRevision` de cada registro e preservando a fila local. Novos clientes devem localizar o cursor por chave, pois o código atual busca somente o primeiro.
- Tipos desconhecidos em uma versão futura causam estado de atualização necessária; não avançar o cursor descartando dados silenciosamente.
- Implantar primeiro a migração compatível do backend, testar clientes antigo/novo e só depois instalar os novos apps. A fase 2 continua sincronizando treinos durante essa transição.

### Conflitos

Edições concorrentes preservam versões local e remota com comparação legível. Perfil permite escolher uma versão; registros corporais permitem manter ambas com novos IDs no registro e nos valores. Sono oferece escolha de versão ou correção da data, respeitando uma noite principal por dia. Duplicatas de noite com IDs distintos têm motivo de conflito específico e não entram nas médias enquanto ambíguas. Exclusões concorrentes não recriam o mesmo UUID. Reaproveitar a outbox offline e tratar perda de resposta/reenvio sem duplicar medições.

Corpo e sono são dados pessoais: nunca incluir valores reais, nascimento, notas, email, tokens ou capturas de conta nos commits/logs de diagnóstico. Usar fixtures fictícias e o backend local/de teste para validações destrutivas. A configuração pessoal continua fora do Git. Esta fase não muda a política de acesso da conta nem promete criptografia de ponta a ponta.

## Ordem de implementação e verificações

| Etapa | Trabalho | Critério para avançar |
|---|---|---|
| 3.1 — Fundação | V3, entidades, parser decimal, datas, métodos e serviços locais | Migrações V1/V2 e regras unitárias passam sem mudar treinos, sessões ou fila |
| 3.2 — Contrato remoto | RPCs v2, compatibilidade v1, snapshots, cursores, fila versionada e RLS | Clientes antigo/novo coexistem; duas identidades isoladas; retries sem duplicatas |
| 3.3 — Corpo | Perfil, registro, histórico e gráficos no Mac/iPhone | Registrar/editar offline e receber os mesmos valores/unidades/métodos no outro aparelho |
| 3.4 — Sono | Formulários, duração, noites, médias e gráficos | Virada do dia, fusos, opcionais e noite duplicada passam nos testes |
| 3.5 — Fechamento | Acessibilidade, regressão, validação física e documentação | Fluxo principal completo e pendências registradas com alcance exato |

Testes necessários:

- Migração em disco V1 → V3 e V2 → V3 preservando IDs, relações, ordem, prescrição, sessão ativa, descanso, revisões, conflitos e mutações enviadas/não enviadas.
- Campos vazios/zero, vírgula/ponto, precisão decimal, unidade errada, duas métricas no mesmo registro e rejeição de composição sem método explícito.
- Nenhuma conversão entre massas ou percentuais; comparação separada por método; gravação e edição no disco sem alterar outros eventos.
- Médias exatamente abaixo/no limiar: 2/3 pesagens, 3/4 noites em 7 dias, 11/12 em 30, 6/7 horários e 4/5 despertares preenchidos. Testar bordas da janela e nenhuma amostra fabricada.
- Sono atravessando meia-noite, mês/ano, mudanças de fuso e horário de verão; média de 23h e 1h perto de meia-noite, nunca meio-dia. Duração baseada nos instantes reais.
- Criação simultânea da mesma noite, edição mudando sua data, exclusão concorrente e resolução sem dupla contagem ou perda de candidatos.
- Modo avião, encerramento/reabertura, rascunho incompleto, falha de disco, correção e sincronização com Mac desligado; perda de resposta e operação repetida.
- Feed v1 com lacunas e vários lotes de tipos novos; migração para cursor v2 recupera tudo; mutações v1 em voo recebem o mesmo recibo, sem reaplicação.
- Troca de conta não revela registros nem rascunhos; RLS e RPCs testadas com duas identidades, anônimo e tentativa de escrita direta.
- Compilar Mac, iPhone e extensão sem iniciar cópias duplicadas. Testar iOS 26 no iPhone já pareado; usar simulador somente se o usuário voltar a autorizar seu uso.
- Claro/escuro, tamanhos mínimos do Mac, teclado, Dynamic Type e VoiceOver; gráficos com valores/legendas acessíveis e histórico textual equivalente.

Antes de ampliar o domínio, repetir as verificações relevantes ainda pendentes da fase 2 (conta, retorno de autenticação, restauração e sincronização), sem afirmar que foram concluídas apenas por compilação.

## Aceite da fase 3

Com a mesma conta nos dois aparelhos: registrar peso, duas medidas e composição com método no Mac; receber no iPhone. Desligar o Mac, ficar offline, registrar uma noite e uma nova medição, encerrar/reabrir o app e corrigir ambos. Reconectar e conferir no Mac valores, unidades, método, horários, opcionais, IDs e quantidades exatos. Repetir sincronização sem criar duplicatas.

Apagar/editar uma medição deve recalcular somente os indicadores que dependem dela, sem mudar treino, prescrição ou sessões. Se não houver dados suficientes, nenhum número ou tendência é inventado. Confirmar que o app continua operando com opcionais vazios e que o conflito de uma noite pode ser resolvido mantendo os dados visíveis até a escolha.

Ao concluir, atualizar este documento com migrações e versões aplicadas, testes executados, instruções de uso e limitações verificadas; atualizar README e ROADMAP. Não marcar a fase concluída enquanto o fluxo entre dispositivos não estiver validado.
