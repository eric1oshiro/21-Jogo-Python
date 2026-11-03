"""Aplicação web local para o jogo de 21."""

import os
import random
from math import isfinite

from flask import Flask, jsonify, render_template, request, session

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "chave-local-de-desenvolvimento")

NAIPES = ["♠", "♥", "♦", "♣"]
VALORES = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
SALDO_INICIAL = 100.0


def criar_baralho():
    baralho = [(valor, naipe) for naipe in NAIPES for valor in VALORES]
    random.shuffle(baralho)
    return baralho


def comprar_carta(baralho):
    if not baralho:
        baralho.extend(criar_baralho())
    return baralho.pop()


def pontuacao(mao):
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
    while total > 21 and ases:
        total -= 10
        ases -= 1
    return total


def formatar_dinheiro(valor):
    return f"{valor:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")


def terminar_rodada(resultado, mensagem):
    session["active"] = False
    session["result"] = resultado
    session["message"] = mensagem


def resolver_natural():
    jogador = session["player"]
    dealer = session["dealer"]
    aposta = session["bet"]
    natural_jogador = pontuacao(jogador) == 21
    natural_dealer = pontuacao(dealer) == 21

    if natural_jogador and natural_dealer:
        session["balance"] = round(session["balance"] + aposta, 2)
        terminar_rodada("push", "Blackjack dos dois: empate. Sua aposta voltou.")
    elif natural_jogador:
        session["balance"] = round(session["balance"] + aposta * 2.5, 2)
        lucro = formatar_dinheiro(aposta * 1.5)
        terminar_rodada("win", f"BLACKJACK! Você ganhou R$ {lucro} de lucro!")
    elif natural_dealer:
        terminar_rodada("lose", f"Você perdeu! O dealer fez blackjack. Perda: R$ {formatar_dinheiro(aposta)}.")


def estado_publico():
    if "balance" not in session:
        session["balance"] = SALDO_INICIAL
    dealer = session.get("dealer", [])
    active = session.get("active", False)
    return {
        "balance": session["balance"],
        "bet": session.get("bet"),
        "active": active,
        "player": [{"value": v, "suit": s} for v, s in session.get("player", [])],
        "player_total": pontuacao(session.get("player", [])),
        "dealer": [
            {"value": v, "suit": s, "hidden": active and i == 0}
            for i, (v, s) in enumerate(dealer)
        ],
        "dealer_total": None if active else pontuacao(dealer),
        "result": session.get("result"),
        "message": session.get("message", "Faça sua aposta para começar uma rodada."),
    }


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/state")
def api_state():
    return jsonify(estado_publico())


@app.post("/api/start")
def api_start():
    dados = request.get_json(silent=True) or {}
    try:
        aposta = round(float(dados.get("bet", 0)), 2)
    except (TypeError, ValueError):
        return jsonify(error="Informe uma aposta válida."), 400

    saldo = session.get("balance", SALDO_INICIAL)
    if not isfinite(aposta) or aposta <= 0 or aposta > saldo:
        return jsonify(error="A aposta precisa ser maior que zero e não pode superar seu saldo."), 400

    baralho = criar_baralho()
    jogador = []
    dealer = []
    for _ in range(2):
        jogador.append(comprar_carta(baralho))
        dealer.append(comprar_carta(baralho))

    session["deck"] = baralho
    session["player"] = jogador
    session["dealer"] = dealer
    session["bet"] = aposta
    session["balance"] = round(saldo - aposta, 2)
    session["active"] = True
    session["result"] = None
    session["message"] = "Sua vez: compre uma carta ou pare."
    resolver_natural()
    return jsonify(estado_publico())


@app.post("/api/action")
def api_action():
    if not session.get("active"):
        return jsonify(error="Comece uma rodada antes de jogar."), 400
    dados = request.get_json(silent=True) or {}
    acao = dados.get("action")

    if acao == "hit":
        jogador = session["player"]
        jogador.append(comprar_carta(session["deck"]))
        if pontuacao(jogador) > 21:
            terminar_rodada("lose", f"Você perdeu! Passou de 21. Perda: R$ {formatar_dinheiro(session['bet'])}.")
        elif pontuacao(jogador) == 21:
            # Ao chegar a 21, a vez do jogador termina automaticamente.
            concluir_turno_dealer()
        else:
            session["message"] = "Mais uma carta ou prefere parar?"
    elif acao == "stand":
        concluir_turno_dealer()
    else:
        return jsonify(error="Ação inválida."), 400

    return jsonify(estado_publico())


def concluir_turno_dealer():
    dealer = session["dealer"]
    while pontuacao(dealer) < 17:
        dealer.append(comprar_carta(session["deck"]))

    total_jogador = pontuacao(session["player"])
    total_dealer = pontuacao(dealer)
    aposta = session["bet"]
    if total_dealer > 21 or total_jogador > total_dealer:
        session["balance"] = round(session["balance"] + aposta * 2, 2)
        terminar_rodada("win", f"VOCÊ GANHOU! Lucro: R$ {formatar_dinheiro(aposta)}.")
    elif total_jogador == total_dealer:
        session["balance"] = round(session["balance"] + aposta, 2)
        terminar_rodada("push", "Empate. Sua aposta voltou para o saldo.")
    else:
        terminar_rodada("lose", f"Você perdeu! O dealer venceu. Perda: R$ {formatar_dinheiro(aposta)}.")


@app.post("/api/reset")
def api_reset():
    session.clear()
    session["balance"] = SALDO_INICIAL
    session["message"] = "Novo jogo! Faça sua aposta para começar."
    return jsonify(estado_publico())


@app.post("/api/new-round")
def api_new_round():
    if session.get("balance", SALDO_INICIAL) <= 0:
        return jsonify(error="Seu saldo acabou. Reinicie o jogo para jogar novamente."), 400
    session.pop("player", None)
    session.pop("dealer", None)
    session.pop("deck", None)
    session.pop("bet", None)
    session["active"] = False
    session["result"] = None
    session["message"] = "Faça sua aposta para começar uma rodada."
    return jsonify(estado_publico())


if __name__ == "__main__":
    app.run(debug=True)
