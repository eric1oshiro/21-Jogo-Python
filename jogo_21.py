"""Jogo de 21 (Blackjack) para jogar no terminal.

Regras usadas: baralho de 52 cartas, dealer compra até 17, blackjack natural
paga 3:2 e empate devolve a aposta. Não há divisão de mãos nem seguro.
"""

import random


NAIPES = ["♠", "♥", "♦", "♣"]
VALORES = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]


def criar_baralho():
    """Cria e embaralha um baralho padrão."""
    baralho = [(valor, naipe) for naipe in NAIPES for valor in VALORES]
    random.shuffle(baralho)
    return baralho


def comprar_carta(baralho, mao):
    """Compra uma carta. Quando necessário, embaralha um novo baralho."""
    if not baralho:
        baralho.extend(criar_baralho())
    mao.append(baralho.pop())


def pontuacao(mao):
    """Calcula o melhor valor da mão sem ultrapassar 21, se possível."""
    total = 0
    ases = 0
    for valor, _ in mao:
        if valor == "A":
            total += 11
            ases += 1
        elif valor in ("J", "Q", "K"):
            total += 10
        else:
            total += int(valor)

    # Cada ás pode valer 1 em vez de 11 para evitar estourar.
    while total > 21 and ases:
        total -= 10
        ases -= 1
    return total


def mostrar_mao(nome, mao, esconder_primeira=False):
    if esconder_primeira:
        cartas = ["??"] + [f"{valor}{naipe}" for valor, naipe in mao[1:]]
        print(f"{nome}: {'  '.join(cartas)}  (carta visível: {pontuacao(mao[1:]) if len(mao) > 1 else 0})")
    else:
        cartas = [f"{valor}{naipe}" for valor, naipe in mao]
        print(f"{nome}: {'  '.join(cartas)}  (total: {pontuacao(mao)})")


def pedir_aposta(saldo):
    while True:
        entrada = input(f"\nSeu saldo é R$ {saldo:.2f}. Quanto deseja apostar? (ou 0 para sair): R$ ").strip().replace(",", ".")
        try:
            aposta = float(entrada)
        except ValueError:
            print("Digite um valor numérico, por exemplo 10 ou 5,50.")
            continue
        if aposta == 0:
            return 0
        if aposta < 0:
            print("A aposta precisa ser maior que zero.")
        elif aposta > saldo:
            print("Você não pode apostar mais do que tem no saldo.")
        else:
            return aposta


def turno_jogador(baralho, jogador, dealer):
    while pontuacao(jogador) < 21:
        print()
        mostrar_mao("Sua mão", jogador)
        mostrar_mao("Dealer", dealer, esconder_primeira=True)
        escolha = input("\n[A] Comprar carta  [P] Parar: ").strip().lower()
        if escolha in ("a", "comprar", "c"):
            comprar_carta(baralho, jogador)
            if pontuacao(jogador) > 21:
                mostrar_mao("Sua mão", jogador)
                print("Você passou de 21!")
                return False
        elif escolha in ("p", "parar", "s", "stand"):
            return True
        else:
            print("Opção não reconhecida. Escolha A ou P.")
    return pontuacao(jogador) == 21


def turno_dealer(baralho, dealer):
    """Estratégia da banca: compra até 17 ou mais."""
    print("\nVez do dealer:")
    mostrar_mao("Dealer", dealer)
    while pontuacao(dealer) < 17:
        print("Dealer compra uma carta...")
        comprar_carta(baralho, dealer)
        mostrar_mao("Dealer", dealer)


def jogar_rodada(baralho, aposta, saldo):
    jogador = []
    dealer = []
    for _ in range(2):
        comprar_carta(baralho, jogador)
        comprar_carta(baralho, dealer)

    print("\n" + "=" * 42)
    print("NOVA RODADA")
    mostrar_mao("Sua mão", jogador)
    mostrar_mao("Dealer", dealer, esconder_primeira=True)

    jogador_natural = pontuacao(jogador) == 21
    dealer_natural = pontuacao(dealer) == 21

    if jogador_natural or dealer_natural:
        mostrar_mao("Dealer", dealer)
        if jogador_natural and dealer_natural:
            print("Blackjack dos dois: empate. A aposta voltou para você.")
        elif jogador_natural:
            premio = aposta * 1.5
            saldo += premio
            print(f"Blackjack! Você ganhou R$ {premio:.2f} (pagamento 3:2).")
        else:
            saldo -= aposta
            print("O dealer fez blackjack. Você perdeu a aposta.")
        return saldo

    saldo -= aposta
    if turno_jogador(baralho, jogador, dealer):
        turno_dealer(baralho, dealer)

    total_jogador = pontuacao(jogador)
    total_dealer = pontuacao(dealer)
    print("\n--- Resultado ---")
    mostrar_mao("Você", jogador)
    mostrar_mao("Dealer", dealer)

    if total_jogador > 21:
        print(f"Você perdeu R$ {aposta:.2f}.")
    elif total_dealer > 21 or total_jogador > total_dealer:
        saldo += aposta * 2
        print(f"Você venceu e recebeu R$ {aposta:.2f} de lucro!")
    elif total_jogador == total_dealer:
        saldo += aposta
        print("Empate. Sua aposta foi devolvida.")
    else:
        print(f"O dealer venceu. Você perdeu R$ {aposta:.2f}.")
    return saldo


def main():
    print("=" * 42)
    print("         JOGO DE 21 - BLACKJACK")
    print("=" * 42)
    print("Chegue o mais perto de 21 sem passar. O dealer para em 17.")
    print("Figuras valem 10; o Ás vale 1 ou 11. Blackjack natural paga 3:2.")
    print("Este jogo usa fichas fictícias e não envolve dinheiro real.\n")

    saldo = 100.0
    baralho = criar_baralho()
    while saldo > 0:
        aposta = pedir_aposta(saldo)
        if aposta == 0:
            break
        saldo = jogar_rodada(baralho, aposta, saldo)
        if saldo <= 0:
            print("\nSeu saldo acabou. Fim de jogo!")
            break

    print(f"\nJogo encerrado. Saldo final: R$ {saldo:.2f}. Até a próxima!")


if __name__ == "__main__":
    main()
