CORREÇÃO PARA REABERTURA DO OBS APÓS DESLIGAMENTO

Entendi o caso: houve uma queda de energia, o OBS foi fechado, e ao abrir novamente as propriedades dos ciclos ainda mostram os valores salvos, mas o script não encontra a mídia do comercial.

Esta versão faz novas buscas automáticas enquanto o OBS termina de carregar e procura as fontes Mídia/VLC também dentro de grupos e cenas aninhadas na cena de comercial.

Para atualizar:
1. Ferramentas > Scripts.
2. Selecione o script antigo comercial_ciclo_4pares.lua e remova com o botão –.
3. Adicione o comercial_ciclo_4pares.lua deste pacote.
4. Confira os menus de cena e tempos. Como os nomes dos campos são mantidos, o OBS normalmente mantém as configurações; confirme após substituir.
5. Não rode simultaneamente outro script de troca de cenas.

O OBS precisa estar aberto para automação funcionar. Cada cena de comercial deve conter uma fonte Mídia/VLC com arquivo válido e Repetir/Loop desativado.
