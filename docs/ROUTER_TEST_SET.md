# Router test set

Phrases that today's keyword rules miss or get wrong: long, rambling and short versions in English, Spanish, German, French, Portuguese, Italian, Dutch, Japanese and Hindi, plus mixed-language speech.

Run it from the Bibbles menu: hold **Option**, open **Developer → Run Router Test Set**. Each phrase and its flags go to the AI router ONLY (no answers, no Worker requests). The results table is copied to the clipboard.

The router prompt's own examples (`RouterPrompt.swift`) are deliberately different from these phrases, so this measures real accuracy.

Flags: `S` hasSelectedText, `C` selectionLooksLikeCode, `R` recentBibblesWriting, `T` textFieldFocused, `F` filesAttached, `H` screenHotkeyUsed.

This file is generated from the same list as `Sources/BibblesApp/Routing/RouterTestSet.swift`; keep them in sync.

| # | language | flags | expected | phrase |
|---|---|---|---|---|
| 1 | English | T | write | I'm not liking a job where I'm working right now. So uh, I want to resign. Uh, so write a mail of resignation to my HR here. |
| 2 | English | T | write | okay so my friend just got engaged and I wanna send her something sweet, can you, like, put a message together for her |
| 3 | Spanish | T | write | No me gusta mi trabajo, así que quiero renunciar… escribe un correo de renuncia a RRHH aquí |
| 4 | German | T | write | Ich mag meinen Job nicht mehr, also… schreib hier eine Kündigungsmail an die Personalabteilung |
| 5 | French | T | write | Mon proprio m'a encore relancé pour le loyer, euh, tu peux lui répondre que je paie lundi |
| 6 | Portuguese | T | write | Meu cliente atrasou o pagamento de novo, né, então manda um e-mail educado cobrando ele |
| 7 | Italian | T | write | Domani non posso venire in ufficio, mi prepari due righe per avvisare il capo? |
| 8 | Dutch | T | write | Mijn collega gaat met pensioen, kun je een leuk afscheidsbericht voor haar maken |
| 9 | Japanese | T | write | 来週の会議に出られないので、えっと、上司に丁寧な欠席のメールを書いてくれる? |
| 10 | Hindi | T | write | कल मेरी छुट्टी है तो, मैनेजर को एक छोटा सा मेल भेजने के लिए लिख दो |
| 11 | Mixed | T | write | Mi jefe me pidió el report, so uh, escribe un email diciéndole que lo mando mañana |
| 12 | English | T | write | The recruiter reached out on LinkedIn and I'm interested but busy this week, so a polite reply asking for next Tuesday would be great |
| 13 | English | R | edit | Hmm, that mail is kind of long, can you, like, cut it down a bit? |
| 14 | Portuguese | R | edit | deixa mais curto |
| 15 | English | R | edit | eh, it sounds a little too stiff, loosen it up |
| 16 | Spanish | R | edit | Mmm no me convence, hazlo más cercano y menos formal |
| 17 | German | R | edit | Das klingt zu hart, kannst du es freundlicher machen |
| 18 | French | R | edit | Ajoute une phrase pour remercier l'équipe à la fin |
| 19 | Italian | R | edit | Troppo lungo, accorcialo per favore |
| 20 | Dutch | R | edit | Kun je er nog een tweede versie van maken, iets grappiger |
| 21 | Japanese | R | edit | もう少し丁寧な感じにして |
| 22 | Hindi | R | edit | इसे थोड़ा और प्रोफेशनल बना दो |
| 23 | Mixed | R | edit | Ye wala thoda boring hai yaar, make it more fun |
| 24 | English | S | fix_text | I wrote this but my English isn't great, can you clean it up? |
| 25 | English | S | fix_text | there's probably a bunch of typos in here, sort them out for me |
| 26 | Spanish | S | fix_text | Revísame esto que escribí, creo que tiene errores de gramática |
| 27 | German | S | fix_text | Kannst du meinen Text hier mal korrekturlesen und verbessern |
| 28 | French | S | fix_text | J'ai écrit ça vite fait, tu peux corriger les fautes |
| 29 | Portuguese | S | fix_text | Dá uma melhorada nesse texto, tá meio confuso |
| 30 | Italian | S | fix_text | Sistemami la grammatica di questo paragrafo |
| 31 | Dutch | S | fix_text | Haal de spelfouten uit dit stuk tekst |
| 32 | Japanese | S | fix_text | この文章の間違いを直してほしい |
| 33 | Hindi | S | fix_text | इस पैराग्राफ में जो गलतियाँ हैं उन्हें ठीक कर दो |
| 34 | Mixed | S | fix_text | Meine Präsentation ist auf Englisch, can you polish the wording a bit |
| 35 | English | SC | fix_code | So this thing keeps crashing when I click save, uh, can you look at what's wrong and fix it? |
| 36 | English | SC | fix_code | this loop never ends and I've been staring at it for an hour, help |
| 37 | English | C | fix_code | the build is failing with some type mismatch thing, sort it |
| 38 | Spanish | SC | fix_code | Este código me da un error de índice, ¿lo puedes arreglar? |
| 39 | German | SC | fix_code | Die Funktion gibt immer undefined zurück, was mache ich falsch |
| 40 | French | SC | fix_code | Mon script plante au démarrage, tu peux le réparer |
| 41 | Portuguese | SC | fix_code | Esse código tá dando erro de sintaxe, ajeita pra mim |
| 42 | Italian | SC | fix_code | Questa query SQL è lentissima, ottimizzala |
| 43 | Dutch | SC | fix_code | Deze functie werkt niet goed met lege lijsten, los het op |
| 44 | Japanese | SC | fix_code | このコード、エラーが出るんだけど直してくれる? |
| 45 | Hindi | SC | fix_code | ये कोड चल नहीं रहा, इसमें क्या गड़बड़ है ठीक करो |
| 46 | Mixed | SC | fix_code | Este endpoint returns 500 every time, ¿qué está mal? |
| 47 | English | S | translate | My boss sent this in German and I have no idea what it says |
| 48 | English | S | translate | can you turn this into French for me, it's going to a client in Paris |
| 49 | Spanish | S | translate | Pásame esto al inglés |
| 50 | German | S | translate | Was heißt das hier auf Deutsch? |
| 51 | French | S | translate | Mets ce passage en anglais |
| 52 | Portuguese | S | translate | Isso aqui tá em japonês, o que quer dizer? |
| 53 | Italian | S | translate | Questo testo è in olandese, me lo rendi in italiano? |
| 54 | Dutch | S | translate | Zet dit even om naar het Engels |
| 55 | Japanese | S | translate | この英文、日本語で何て言ってるの? |
| 56 | Hindi | S | translate | इसका हिंदी में मतलब बताओ |
| 57 | Mixed | S | translate | Ye Spanish mein kya likha hai, English mein bata do |
| 58 | English | — | screen | I opened this settings page and honestly I don't get what this toggle does |
| 59 | Japanese | — | screen | この画面のエラーは何? |
| 60 | English | — | screen | okay so there's like a popup thing in the corner asking for permission, should I allow it |
| 61 | English | — | screen | which of these buttons actually saves the project |
| 62 | Spanish | — | screen | ¿Qué me está diciendo este mensaje que me salió? |
| 63 | German | — | screen | Was zeigt mir dieser Graph da gerade |
| 64 | French | — | screen | C'est quoi cette icône rouge en haut à droite |
| 65 | Portuguese | — | screen | Esse aviso que apareceu é perigoso? |
| 66 | Italian | — | screen | Dove trovo l'opzione per esportare in PDF in questa app? |
| 67 | Dutch | — | screen | Wat moet ik hier invullen bij dit veld |
| 68 | Hindi | — | screen | स्क्रीन पर ये जो एरर आ रहा है उसका क्या मतलब है |
| 69 | Mixed | H | screen | Erklär mir das hier, what's going on in this chart |
| 70 | English | — | search | I was wondering, uh, how much is bitcoin going for right now? |
| 71 | German | — | search | was gibt's Neues bei Apple? |
| 72 | English | — | search | did the flight from Delhi to London get cancelled today |
| 73 | English | — | search | what did the Fed decide on rates this week |
| 74 | Spanish | — | search | ¿Cómo quedó el partido del Real Madrid ayer? |
| 75 | French | — | search | Il y a des grèves de train prévues cette semaine ? |
| 76 | Portuguese | — | search | Qual é a cotação do dólar agora? |
| 77 | Italian | — | search | Che tempo fa a Milano nel weekend? |
| 78 | Dutch | — | search | Hoe laat gaat de supermarkt hier vandaag dicht |
| 79 | Japanese | — | search | 今日の東京の天気どう? |
| 80 | Hindi | — | search | आज की बड़ी खबरें क्या हैं |
| 81 | Mixed | — | search | Yaar, latest iPhone ka price India mein kitna chal raha hai |
| 82 | English | — | deep | My app works on my Mac but breaks on my friend's, I've tried everything, why? |
| 83 | English | — | deep | walk me through how I'd design a database for a hospital with patients, doctors, shifts and billing |
| 84 | English | — | deep | if I invest 500 a month for 20 years at a varying return, and inflation is 3 percent, what's the real value, show the maths |
| 85 | Spanish | — | deep | Analiza a fondo las ventajas y riesgos de mudar toda la empresa a la nube |
| 86 | German | — | deep | Unsere Datenbank wird bei vielen Nutzern extrem langsam, wir haben Indizes schon geprüft, was können wir noch tun |
| 87 | French | — | deep | Explique-moi rigoureusement pourquoi l'algorithme de Dijkstra ne marche pas avec des poids négatifs |
| 88 | Portuguese | — | deep | Monta um plano detalhado de estudos de seis meses para eu virar engenheiro de dados |
| 89 | Italian | — | deep | Confronta in dettaglio tre strategie di pricing per un SaaS B2B e dimmi quale scegliere |
| 90 | Dutch | — | deep | Leg stap voor stap uit hoe ik deze kansberekening met drie dobbelstenen oplos |
| 91 | Japanese | — | deep | マイクロサービスとモノリス、うちの10人チームにはどっちがいいか詳しく比較して |
| 92 | Hindi | — | deep | मेरे बिज़नेस के लिए पूरी मार्केटिंग स्ट्रेटेजी विस्तार से बनाओ |
| 93 | Mixed | — | deep | Mi app de React se re-renderiza infinitamente only in production, I've checked useEffect deps, what else? |
| 94 | English | — | command | I'm bored, put on some music or something |
| 95 | English | — | command | ugh it's so bright, can you dim things a bit |
| 96 | English | — | command | get Slack open for me |
| 97 | Spanish | — | command | Pon algo de música tranquila |
| 98 | German | — | command | Mach mal den Ton leiser |
| 99 | French | — | command | Ouvre-moi Safari s'il te plaît |
| 100 | Portuguese | — | command | Bota o modo escuro |
| 101 | Italian | — | command | Ricordami di comprare il latte alle sette |
| 102 | Dutch | — | command | Zet de muziek op pauze |
| 103 | Japanese | — | command | 音量をちょっと上げて |
| 104 | Hindi | — | command | कोई अच्छा गाना चला दो |
| 105 | Mixed | — | command | Kal subah 9 baje ka meeting calendar mein daal do |
| 106 | English | — | form_fill | There's this long sign-up thing here, can you do it for me? |
| 107 | English | — | form_fill | just pop my name and email into these boxes |
| 108 | English | — | form_fill | this job application wants all my details again, handle it |
| 109 | Spanish | — | form_fill | Rellena este formulario con mis datos |
| 110 | German | — | form_fill | Trag bitte meine Adresse in die Felder ein |
| 111 | French | — | form_fill | Complète le formulaire d'inscription avec mes infos |
| 112 | Portuguese | — | form_fill | Preenche esse cadastro pra mim |
| 113 | Italian | — | form_fill | Compila tu i campi di questo modulo |
| 114 | Dutch | — | form_fill | Vul dit contactformulier voor me in |
| 115 | Japanese | — | form_fill | このフォームに私の情報を入力して |
| 116 | Hindi | — | form_fill | ये फॉर्म मेरी डिटेल्स से भर दो |
| 117 | English | — | file_action | I downloaded a PDF about taxes last week and now I can't find it anywhere |
| 118 | English | — | file_action | my desktop is a total mess, sort everything into folders |
| 119 | Spanish | — | file_action | Busca el contrato que guardé el mes pasado |
| 120 | German | — | file_action | Benenn die Datei in Rechnung März um |
| 121 | French | — | file_action | Crée un dossier Projets sur le bureau |
| 122 | Portuguese | — | file_action | Move as fotos da viagem pra uma pasta nova |
| 123 | Italian | — | file_action | Dov'è finito il file Excel del budget? |
| 124 | Dutch | — | file_action | Zoek mijn cv op deze Mac |
| 125 | Japanese | — | file_action | デスクトップに「請求書」ってフォルダ作って |
| 126 | Hindi | — | file_action | डाउनलोड्स में जो पुरानी फाइलें हैं उन्हें एक फोल्डर में डाल दो |
| 127 | Mixed | — | file_action | Mera resume kahin save kiya tha, find it on my Mac |
| 128 | English | — | simple | what's a good name for my cat? |
| 129 | English | — | simple | I can't write today, I'm so tired |
| 130 | English | — | simple | honestly I've been feeling kinda unmotivated lately, any tips to get going again |
| 131 | English | T | simple | how long should I boil an egg for it to be soft |
| 132 | Spanish | — | simple | ¿Por qué el cielo es azul? |
| 133 | German | — | simple | Ich schreibe heute keine Mails mehr, ich bin fertig |
| 134 | French | — | simple | Donne-moi une idée de dîner rapide |
| 135 | Portuguese | — | simple | Qual a diferença entre vírus e bactéria? |
| 136 | Italian | — | simple | Come si dice 'grazie' in giapponese? |
| 137 | Dutch | — | simple | Wat is een goed boek om Engels te leren |
| 138 | Japanese | — | simple | 猫の名前、何かいいのある? |
| 139 | Hindi | — | simple | अच्छी नींद के लिए क्या करना चाहिए |
| 140 | English | — | unclear | uh, the, you know, that one |
| 141 | English | T | unclear | do the thing |
| 142 | Spanish | — | unclear | eso, lo de antes |
| 143 | German | — | unclear | Ähm, ja, also |
| 144 | Mixed | — | unclear | haan wo wala |
| 145 | Mixed | — | form_fill | Ye registration form hai, fill it with my details please |
| 146 | English | R | edit | okay that's good but, uh, the second paragraph sounds weird, rewrite just that part |
| 147 | English | S | fix_text | I'm sending this to my professor so, um, make sure there are no mistakes in it |
| 148 | English | S | translate | a customer wrote this review in Portuguese, what are they complaining about |
| 149 | Spanish | T | write | Contéstale a este cliente que su pedido sale el lunes |
| 150 | English | — | search | how much is a return ticket from Mumbai to Goa this Friday |
