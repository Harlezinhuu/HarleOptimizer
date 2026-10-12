# Assinatura digital (SignPath Foundation)

A assinatura tira o aviso "O Windows protegeu o computador" do SmartScreen com o tempo e mostra quem publicou o exe. A SignPath Foundation assina de graça projetos de código aberto, desde que o exe seja compilado pelo GitHub Actions a partir deste repositório (é o que o workflow `.github/workflows/build.yml` já faz).

## O que fazer (uma vez)

1. Ative a verificação em duas etapas na conta do GitHub (a SignPath exige).
2. Peça a entrada no programa em https://signpath.org/apply informando:
   - Repositório: https://github.com/Harlezinhuu/HarleOptimizer
   - Licença: GPL-3.0
   - O que o programa faz: otimizador de Windows para jogos, com todas as mudanças reversíveis e código aberto.
3. Quando aprovarem, a SignPath cria a organização e o projeto. Instale o app da SignPath no repositório, como eles indicarem.
4. No GitHub, em **Settings → Secrets and variables → Actions**:
   - Segredo `SIGNPATH_API_TOKEN`: o token de API que a SignPath fornece.
   - Variável `SIGNPATH_ORGANIZATION_ID`: o ID da organização na SignPath.
   - Variáveis opcionais `SIGNPATH_PROJECT_SLUG` (padrão `harle-optimizer`) e `SIGNPATH_POLICY_SLUG` (padrão `release-signing`), se os nomes forem outros.

A partir daí, cada Release sai com o exe assinado e o texto "Assinado digitalmente (SignPath Foundation)". Até lá, o workflow publica o exe sem assinatura, com o SHA-256.

## Observações
- O SmartScreen não some na hora: ele leva em conta a reputação do certificado, que cresce com os downloads.
- A SignPath revisa o que é assinado. Componentes de terceiros embutidos (PresentMon, da Intel, licença MIT) estão listados em `build/PresentMon-LICENSE.txt`.
