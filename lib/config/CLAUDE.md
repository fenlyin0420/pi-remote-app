# Camada `config/`

## Propósito

Custodiar todas as decisões de orquestração do aplicativo: bootstrapping,
configuração de dependências (`auto_injector`), ambientes, chaves, integrações
globais. Esta camada conhece todas as outras — é o único lugar com essa
permissão.

## Deve fazer

1. **Declarar bindings**: toda dependência compartilhada nasce aqui via
   `injector.add...`. Repositórios, serviços, ViewModels — tudo passa pelo
   registry.
2. **Usar injeção automática**: prefira passar a referência do construtor
   (`MyClass.new`) em vez de instanciar manualmente. O `AutoInjector` resolve
   parâmetros sozinho.
3. **Isolar setup**: inicializações de SDKs, logs, rotas, temas globais
   acontecem em funções claramente nomeadas (`setupDependencies`,
   `disposeDependencies`, `bootstrap`).
4. **Confiar em contratos**: use apenas interfaces expostas por `domain/`,
   `data/` (services) e `ui/` (ViewModels) — não crie lógica de negócio.
5. **Documentar switches**: variáveis de ambiente e feature flags precisam de
   descrição neste arquivo ou em `.env.example`.

## Não deve fazer

1. **Codificar regras de domínio** — nenhum cálculo, validação ou regra de
   negócio mora aqui.
2. **Criar singletons manuais** — sempre use o `AutoInjector` para controlar
   ciclo de vida.
3. **Importar widgets ou páginas** — manter-se independente da camada `ui/`
   (exceto declarações de tipos para registrar ViewModels).
4. **Executar chamadas de rede** — configure clientes, mas não consuma
   serviços diretamente.

## Estrutura sugerida

```
config/
├── dependencies.dart    # setupDependencies / disposeDependencies
├── env.dart             # leitura de --dart-define e feature flags
├── theme.dart           # ThemeData global
└── utils/               # helpers horizontais (ver utils/CLAUDE.md se existir)
```

## Vocabulário

- **Injector** — fonte única de verdade para dependências.
- **Binding** — contrato que associa um tipo concreto ao seu provedor dentro
  do injector.
- **Bootstrap** — sequência de inicialização do app antes do `runApp`.
