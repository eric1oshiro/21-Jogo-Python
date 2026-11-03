# Jogo de 21 — Blackjack

Um jogo simples de 21 (Blackjack) feito em Python. Jogue no navegador contra o dealer ou use a versão original no terminal. O projeto usa fichas fictícias e não envolve dinheiro real.

## Versão web

### Requisitos

- Python 3.10 ou superior
- pip

### Como executar

1. Baixe ou clone este repositório.
2. (Opcional) Crie e ative um ambiente virtual:

   ```bash
   python -m venv .venv
   ```

   Windows PowerShell:

   ```powershell
   .\.venv\Scripts\Activate.ps1
   ```

   macOS/Linux:

   ```bash
   source .venv/bin/activate
   ```

3. Instale a dependência:

   ```bash
   pip install -r requirements.txt
   ```

4. Inicie o servidor:

   ```bash
   python app.py
   ```

5. Abra [http://127.0.0.1:5000](http://127.0.0.1:5000) no navegador.

## Como jogar

- Faça uma aposta usando seu saldo inicial de R$ 100 em fichas.
- Clique em **Comprar carta** para receber outra carta ou em **Parar** para encerrar sua vez.
- O dealer compra cartas até chegar a 17.
- Cartas numéricas valem seu número; J, Q e K valem 10; Ás vale 1 ou 11.
- Blackjack natural paga 3:2; empate devolve a aposta.
- **Reiniciar saldo** inicia um novo jogo com R$ 100 em fichas.

## Versão de terminal

O jogo original em Python continua disponível:

```bash
python jogo_21.py
```

## Tecnologias

- Python e Flask para as regras e o servidor local
- HTML, CSS e JavaScript para a interface no navegador

## Estrutura

```text
.
├── app.py              # servidor Flask e regras da versão web
├── jogo_21.py          # versão de terminal
├── requirements.txt    # dependências Python
├── templates/
│   └── index.html       # mesa do jogo
└── static/
    ├── game.js          # ações e atualização da mesa
    └── style.css        # visual responsivo e cartas
```

## Regras e escopo

O dealer para em 17. Esta versão não inclui divisão de mãos, seguro ou apostas paralelas. A mesa pode ser executada localmente; para publicar o jogo na internet será necessário configurar um serviço de hospedagem Python e uma chave secreta própria para a sessão Flask.
