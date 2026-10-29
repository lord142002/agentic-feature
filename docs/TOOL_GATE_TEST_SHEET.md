# Tool Gate — test sheet

## How to measure (about 20 minutes)

1. Build and install as usual.
2. Hold **Option** and click the Bibbles menu → **Developer**:
   - turn on **Record Tool Gate Log**
   - check that **Tool Gate: On** is ticked
3. Ask every question below (speak with ⌃⌥ or type with ⌃⌃). Wait for each answer.
4. Bibbles menu (Option) → Developer → **Copy Tool Gate Log**, paste it somewhere.
5. Developer → **Clear Tool Gate Log**, then click **Tool Gate** so it shows **Off**.
6. Ask the same questions again, copy the log again.
7. Paste both tables to Claude. Turn **Tool Gate** back **On** afterwards.

The log holds the last 50 requests, so copy after every ~45 questions.
It never contains your questions — only language, route, tier, tokens and timings.
Screen questions are logged as "screen / vision" without tokens (screen help has its own request).

## Questions (one per language per route)

| Route | English | German | French | Spanish | Hinglish |
|---|---|---|---|---|---|
| localAnswer | What's the time in Tokyo? | Wie spät ist es in Tokio? | Quelle heure est-il à Tokyo ? | ¿Qué hora es en Tokio? | Dubai mein kitne baje hain? |
| weather | Weather in Berlin | Wetter in Berlin | Météo à Paris | Tiempo en Madrid | Kal Mumbai ka mausam kaisa hoga? |
| simple | What is photosynthesis? | Was ist Photosynthese? | Qu'est-ce que la photosynthèse ? | ¿Qué es la fotosíntesis? | Photosynthesis kya hota hai? |
| search | Bitcoin price today | Bitcoin Preis heute | Prix du bitcoin aujourd'hui | Precio del bitcoin hoy | Aaj bitcoin ka rate kya hai? |
| write ¹ | Write an email to my boss asking for Friday off | Schreib eine E-Mail an meinen Chef, dass ich Freitag frei brauche | Écris un mail à mon patron pour demander mon vendredi | Escribe un correo a mi jefe pidiendo el viernes libre | Boss ko Friday chhutti ke liye mail likho |
| edit ² | Make it shorter | Mach es kürzer | Rends-le plus court | Hazlo más corto | Isko chhota karo |
| screen ³ | What is this error on my screen? | Was ist dieser Fehler auf meinem Bildschirm? | Quelle est cette erreur sur mon écran ? | ¿Qué es este error en mi pantalla? | Screen pe ye error kya hai? |
| deep ⁴ | Prove step by step that √2 is irrational, using √2 = a/b ⇒ 2b² = a² | Beweise Schritt für Schritt, dass √2 irrational ist: √2 = a/b ⇒ 2b² = a² | Démontre étape par étape que √2 est irrationnel : √2 = a/b ⇒ 2b² = a² | Demuestra paso a paso que √2 es irracional: √2 = a/b ⇒ 2b² = a² | Step by step samjhao ki √2 irrational kyun hai: √2 = a/b ⇒ 2b² = a² |
| unclear | Can you help me with this? | Kannst du mir dabei helfen? | Tu peux m'aider avec ça ? | ¿Me ayudas con esto? | Isme meri help karo |

¹ Click into an empty Notes note (or a mail body) first; Bibbles types the text there.
² Ask right after the write question in the same language (it changes what Bibbles just wrote).
³ Have an error message visible on screen (any app).
⁴ Deep only runs when your plan has Deep Tasks left; otherwise the log shows "light".

## What to look for

- **route**: should match the row. "unclear" is the safe fallback (today's behaviour).
- **input tokens**: should drop for simple, write, edit and search (shorter prompt, less history).
- **first word ms / total ms**: should be the same or lower with the gate on.
- **Answer language**: every answer should come back in the language you asked in.

## Turning it off for launch

If anything is worse: Developer → **Tool Gate: Off**. The app then behaves exactly as before.
For all users, ship with the gate off by running once:
`defaults write <bundle id> bibbles.toolGateEnabled -bool NO` — or change the default in
`ToolGate.isEnabled` (Routing/ToolGate.swift) from `true` to `false`.
