import Foundation

/// Every keyword table the Tool Gate uses, in one place, one table per
/// language. Phrases are written in their normal spelling; matching ignores
/// case, accents and punctuation (see `ToolGateText.fold`).
///
/// A phrase ending in `*` matches any word that starts with it
/// ("bildschirm*" matches "Bildschirms"). Phrases in scripts written without
/// spaces (Chinese, Japanese) match anywhere in the text.
///
/// Language keys: ISO-639-1 codes, plus "hinglish" (Hindi in Latin letters).
/// The list covers every language of the dictation model; tables for the
/// less common languages are deliberately short and conservative: when they
/// miss, the request simply takes today's (unclear) route.
enum ToolGateLexicon {
    /// Languages the gate knows. Order matters only for display.
    static let languages = ["en", "de", "fr", "es", "it", "pt", "nl", "hi", "hinglish",
                            "tr", "ru", "ar", "ja", "ko", "vi", "uk", "pl", "sv", "cs", "nb",
                            "da", "bg", "fi", "hr", "sk", "zh", "hu", "ro", "et"]

    // MARK: Weather

    static let weather: [String: [String]] = [
        "en": ["weather", "temperature", "forecast", "is it raining", "will it rain", "how hot", "how cold"],
        "de": ["wetter", "wetters", "wettervorhersage", "temperatur", "regnet es", "wird es regnen", "wie warm", "wie kalt"],
        "fr": ["météo", "quel temps", "temps qu'il fait", "température", "prévisions", "va-t-il pleuvoir", "il pleut"],
        "es": ["qué tiempo", "el tiempo en", "tiempo en", "clima", "temperatura", "pronóstico", "va a llover", "está lloviendo"],
        "it": ["meteo", "che tempo fa", "tempo a", "tempo fa a", "temperatura", "previsioni", "pioverà", "sta piovendo"],
        "pt": ["previsão do tempo", "tempo em", "tempo no", "tempo na", "clima", "temperatura", "vai chover", "está chovendo"],
        "nl": ["weer in", "het weer", "weerbericht", "weersverwachting", "temperatuur", "gaat het regenen", "regent het"],
        "hi": ["मौसम", "तापमान", "बारिश"],
        "hinglish": ["mausam", "barish", "baarish", "kitni garmi", "kitni thand", "weather kaisa"],
        "tr": ["hava durumu", "hava nasıl", "sıcaklık", "yağmur yağacak"],
        "ru": ["погода", "погоду", "температура"],
        "ar": ["الطقس", "حالة الجو", "درجة الحرارة"],
        "ja": ["天気", "気温"],
        "ko": ["날씨", "기온"],
        "vi": ["thời tiết", "nhiệt độ"],
        "uk": ["погода", "погоду", "температура"],
        "pl": ["pogoda", "pogodę", "temperatura"],
        "sv": ["väder", "vädret", "temperatur"],
        "cs": ["počasí", "teplota"],
        "nb": ["været", "vær i", "temperatur"],
        "da": ["vejret", "vejr i", "temperatur"],
        "bg": ["времето", "температура"],
        "fi": ["sää", "säätila", "lämpötila"],
        "hr": ["vrijeme u", "prognoza", "temperatura"],
        "sk": ["počasie", "teplota"],
        "zh": ["天气", "天氣", "气温", "氣溫"],
        "hu": ["időjárás", "hőmérséklet"],
        "ro": ["vremea", "temperatura"],
        "et": ["ilm", "ilmateade", "temperatuur"]
    ]

    /// Words around a weather question that are never the city.
    static let weatherFiller: Set<String> = ToolGateText.foldSet([
        "today", "tomorrow", "now", "right", "please", "like", "outside",
        "heute", "morgen", "jetzt", "gerade", "bitte", "aktuell",
        "aujourd'hui", "demain", "maintenant", "actuellement", "s'il", "vous", "plaît",
        "hoy", "mañana", "ahora", "por", "favor", "hace",
        "oggi", "domani", "adesso", "ora", "per", "favore",
        "hoje", "amanhã", "agora", "faz", "está",
        "vandaag", "nu", "alstublieft",
        "aaj", "kal", "abhi", "kaisa", "kaisi", "hai", "hoga", "hogi",
        "the", "a", "le", "la", "les", "el", "il", "lo", "o", "de", "der", "die", "das", "het", "van", "of", "di", "du", "des", "do", "da"
    ])

    // MARK: Time and date

    /// "What time is it" in each language (a place may follow).
    static let timeQuestion: [String: [String]] = [
        "de": ["wie spät ist es", "wie viel uhr ist es", "wieviel uhr ist es", "uhrzeit in", "wie spät"],
        "fr": ["quelle heure est-il", "quelle heure il est", "quelle heure est il", "l'heure à", "l'heure en", "l'heure au"],
        "es": ["qué hora es", "que hora es", "la hora en", "qué hora son"],
        "it": ["che ore sono", "che ora è", "che ora e", "l'ora a", "l'ora in"],
        "pt": ["que horas são", "que horas sao", "que horas é", "as horas em", "a hora em"],
        "nl": ["hoe laat is het", "hoe laat", "hoeveel uur is het"],
        "hi": ["कितने बजे", "क्या समय", "समय क्या", "टाइम क्या"],
        "tr": ["saat kaç"],
        "ru": ["который час", "сколько времени"],
        "ar": ["كم الساعة", "كم الوقت"],
        "ja": ["何時"],
        "ko": ["몇 시"],
        "vi": ["mấy giờ"],
        "uk": ["котра година", "скільки часу"],
        "pl": ["która godzina", "ktora godzina"],
        "sv": ["vad är klockan", "hur mycket är klockan"],
        "cs": ["kolik je hodin"],
        "nb": ["hva er klokken", "hvor mye er klokken"],
        "da": ["hvad er klokken", "hvor mange er klokken"],
        "bg": ["колко е часът", "колко часа е"],
        "fi": ["paljonko kello on", "mitä kello on", "paljonko kello"],
        "hr": ["koliko je sati"],
        "sk": ["koľko je hodín"],
        "zh": ["几点", "幾點"],
        "hu": ["hány óra van", "mennyi az idő"],
        "ro": ["cât e ceasul", "ce oră este", "cat e ora"],
        "et": ["mis kell on"]
    ]

    /// "What's the date / what day is it" in each language.
    static let dateQuestion: [String: [String]] = [
        "de": ["welches datum", "welcher tag ist heute", "der wievielte ist heute", "welcher wochentag"],
        "fr": ["quelle est la date", "quel jour sommes-nous", "quel jour on est", "quel jour est-on", "on est quel jour"],
        "es": ["qué fecha es", "que fecha es", "qué día es hoy", "que dia es hoy"],
        "it": ["che giorno è oggi", "che giorno e oggi", "che data è", "che data e oggi"],
        "pt": ["que dia é hoje", "que dia e hoje", "qual é a data", "qual a data de hoje"],
        "nl": ["welke datum", "welke dag is het", "wat is de datum"],
        "hi": ["आज क्या तारीख", "आज कौन सा दिन", "आज की तारीख"],
        "tr": ["bugün ayın kaçı", "bugün hangi gün", "tarih ne"],
        "ru": ["какое сегодня число", "какой сегодня день"],
        "ar": ["ما هو التاريخ", "ما تاريخ اليوم", "أي يوم اليوم"],
        "ja": ["今日は何日", "今日は何曜日"],
        "ko": ["오늘 며칠", "오늘 무슨 요일"],
        "vi": ["hôm nay là ngày mấy", "hôm nay là thứ mấy"],
        "uk": ["яке сьогодні число", "який сьогодні день"],
        "pl": ["jaki dziś dzień", "którego dzisiaj", "jaka jest data"],
        "sv": ["vilket datum är det", "vilken dag är det"],
        "cs": ["kolikátého je", "jaký je dnes den"],
        "nb": ["hvilken dato er det", "hvilken dag er det"],
        "da": ["hvilken dato er det", "hvilken dag er det"],
        "bg": ["коя дата е днес", "кой ден е днес"],
        "fi": ["mikä päivä tänään on", "monesko päivä"],
        "hr": ["koji je danas datum", "koji je danas dan"],
        "sk": ["koľkého je dnes", "aký je dnes deň"],
        "zh": ["今天几号", "今天幾號", "今天星期几"],
        "hu": ["hányadika van", "milyen nap van ma"],
        "ro": ["ce dată este azi", "ce zi este azi"],
        "et": ["mis kuupäev on", "mis päev täna on"]
    ]

    /// Words that introduce a place: "in", "à", "en", "em", "a"…
    static let placePrepositions: Set<String> = ToolGateText.foldSet([
        "in", "at", "for", "à", "a", "au", "aux", "en", "em", "no", "na", "nel", "nella", "nello", "im",
        "für", "pour", "para", "per", "voor", "te", "op", "w", "we", "v", "ve", "u", "i", "på", "в", "во", "у",
        "pe", "din", "da", "de"
    ])

    /// Time-zone identifiers for places, including their names in other
    /// languages ("Tokio", "Tóquio", "Londres", "東京"). The English names of
    /// time-zone cities are also found automatically.
    static let placeZones: [String: String] = {
        let groups: [String: [String]] = [
            "Asia/Tokyo": ["tokyo", "tokio", "tóquio", "tokió", "japan", "japon", "japón", "giappone", "japão", "東京", "日本", "도쿄", "токио", "токіо", "طوكيو", "टोक्यो"],
            "Europe/London": ["london", "londres", "londra", "londen", "londýn", "londyn", "лондон", "ロンドン", "伦敦", "倫敦", "런던", "لندن", "लंदन", "uk", "england", "angleterre", "inglaterra", "inghilterra"],
            "America/New_York": ["new york", "nueva york", "nova iorque", "nova york", "new-york", "nowy jork", "нью-йорк", "ニューヨーク", "纽约", "紐約", "뉴욕", "نيويورك", "न्यूयॉर्क", "washington", "boston", "miami"],
            "America/Los_Angeles": ["los angeles", "los ángeles", "san francisco", "california", "californie", "kalifornien", "seattle", "ロサンゼルス", "洛杉矶", "로스앤젤레스"],
            "America/Chicago": ["chicago", "texas", "dallas", "houston"],
            "America/Toronto": ["toronto", "canada", "kanada", "canadá"],
            "America/Mexico_City": ["mexico city", "ciudad de méxico", "méxico", "mexiko", "messico"],
            "America/Sao_Paulo": ["são paulo", "sao paulo", "rio de janeiro", "brasil", "brazil", "brasilien", "brésil"],
            "America/Argentina/Buenos_Aires": ["buenos aires", "argentina", "argentinien", "argentine"],
            "Europe/Paris": ["paris", "parís", "parigi", "parijs", "paryż", "париж", "パリ", "巴黎", "파리", "باريس", "पेरिस", "france", "frankreich", "francia", "frança", "frankrijk"],
            "Europe/Berlin": ["berlin", "berlín", "berlino", "berlijn", "берлин", "ベルリン", "柏林", "베를린", "برلين", "बर्लिन", "germany", "deutschland", "allemagne", "alemania", "germania", "alemanha", "duitsland", "munich", "münchen", "hamburg", "frankfurt"],
            "Europe/Madrid": ["madrid", "barcelona", "spain", "españa", "spanien", "espagne", "spagna", "espanha", "spanje"],
            "Europe/Rome": ["rome", "roma", "rom", "rzym", "рим", "ローマ", "罗马", "로마", "italy", "italia", "italien", "italie", "itália", "italië", "milan", "milano", "mailand"],
            "Europe/Lisbon": ["lisbon", "lisboa", "lissabon", "lisbonne", "lisbona", "portugal", "portogallo"],
            "Europe/Amsterdam": ["amsterdam", "netherlands", "nederland", "niederlande", "pays-bas", "países bajos", "paesi bassi", "holanda"],
            "Europe/Brussels": ["brussels", "bruxelles", "brüssel", "bruselas", "brussel", "belgium", "belgique", "belgien", "bélgica"],
            "Europe/Zurich": ["zurich", "zürich", "geneva", "genève", "genf", "switzerland", "schweiz", "suisse", "suiza", "svizzera", "suíça"],
            "Europe/Vienna": ["vienna", "wien", "vienne", "viena", "austria", "österreich", "autriche"],
            "Europe/Stockholm": ["stockholm", "estocolmo", "sweden", "sverige", "schweden", "suède", "suecia"],
            "Europe/Oslo": ["oslo", "norway", "norge", "norwegen", "norvège", "noruega"],
            "Europe/Copenhagen": ["copenhagen", "københavn", "kopenhagen", "copenhague", "denmark", "danmark", "dänemark"],
            "Europe/Helsinki": ["helsinki", "finland", "suomi", "finnland", "finlande", "finlandia"],
            "Europe/Warsaw": ["warsaw", "warszawa", "warschau", "varsovie", "varsovia", "poland", "polska", "polen", "pologne", "polonia"],
            "Europe/Prague": ["prague", "praha", "prag", "praga", "czechia", "česko"],
            "Europe/Istanbul": ["istanbul", "estambul", "turkey", "türkiye", "turquie", "turquía", "ankara"],
            "Europe/Moscow": ["moscow", "moskau", "moscou", "moscú", "mosca", "moskwa", "москва", "москве", "モスクワ", "莫斯科", "모스크바", "موسكو", "मास्को", "russia", "russland", "russie", "rusia"],
            "Europe/Kyiv": ["kyiv", "kiev", "київ", "києві", "киев", "ukraine", "україна"],
            "Europe/Athens": ["athens", "athen", "athènes", "atenas", "atene", "greece", "griechenland"],
            "Europe/Bucharest": ["bucharest", "bucurești", "bukarest", "romania", "românia", "rumänien"],
            "Europe/Budapest": ["budapest", "hungary", "magyarország", "ungarn"],
            "Europe/Sofia": ["sofia", "софия", "bulgaria", "българия"],
            "Europe/Zagreb": ["zagreb", "croatia", "hrvatska", "kroatien"],
            "Europe/Bratislava": ["bratislava", "slovakia", "slovensko"],
            "Europe/Tallinn": ["tallinn", "estonia", "eesti"],
            "Europe/Dublin": ["dublin", "ireland", "irland", "irlande", "irlanda"],
            "Asia/Kolkata": ["india", "indien", "inde", "índia", "भारत", "delhi", "new delhi", "दिल्ली", "mumbai", "मुंबई", "bombay", "bangalore", "bengaluru", "chennai", "hyderabad", "pune", "kolkata", "jaipur", "noida", "gurgaon", "gurugram"],
            "Asia/Dubai": ["dubai", "dubái", "دبي", "दुबई", "uae", "abu dhabi"],
            "Asia/Riyadh": ["riyadh", "الرياض", "saudi arabia", "السعودية"],
            "Africa/Cairo": ["cairo", "القاهرة", "kairo", "le caire", "el cairo", "egypt", "مصر"],
            "Asia/Singapore": ["singapore", "singapur", "singapour", "cingapura", "新加坡"],
            "Asia/Shanghai": ["beijing", "peking", "pékin", "pekín", "pechino", "pequim", "shanghai", "北京", "上海", "中国", "china", "chine"],
            "Asia/Hong_Kong": ["hong kong", "香港"],
            "Asia/Seoul": ["seoul", "séoul", "seúl", "서울", "ソウル", "首尔", "korea", "korée", "corea", "한국"],
            "Asia/Bangkok": ["bangkok", "thailand", "tailandia"],
            "Asia/Ho_Chi_Minh": ["ho chi minh", "hà nội", "hanoi", "vietnam", "việt nam"],
            "Asia/Jakarta": ["jakarta", "indonesia", "indonesien"],
            "Asia/Karachi": ["karachi", "lahore", "islamabad", "pakistan"],
            "Asia/Dhaka": ["dhaka", "bangladesh"],
            "Asia/Kathmandu": ["kathmandu", "nepal"],
            "Australia/Sydney": ["sydney", "melbourne", "australia", "australien", "australie", "austrália"],
            "Pacific/Auckland": ["auckland", "new zealand", "neuseeland", "nouvelle-zélande", "nueva zelanda"],
            "Africa/Johannesburg": ["johannesburg", "cape town", "south africa", "südafrika", "sudáfrica"],
            "Africa/Lagos": ["lagos", "nigeria"]
        ]
        var zones: [String: String] = [:]
        for (identifier, places) in groups {
            for place in places { zones[ToolGateText.fold(place)] = identifier }
        }
        return zones
    }()

    // MARK: Live information (route: search)

    static let liveInfo: [String: [String]] = [
        "en": ["price of", "price today", "stock price", "share price", "exchange rate", "news", "headlines", "live score",
               "who won", "bitcoin", "btc", "ethereum", "crypto price", "gold price", "box office"],
        "de": ["preis", "preise", "kurs", "aktienkurs", "wechselkurs", "nachrichten", "neuigkeiten", "schlagzeilen",
               "spielstand", "wer hat gewonnen", "bitcoin", "goldpreis", "benzinpreis", "börse"],
        "fr": ["prix", "cours", "taux de change", "actualités", "actualité", "nouvelles", "infos", "score", "qui a gagné",
               "bitcoin", "bourse", "cours de l'or"],
        "es": ["precio", "precios", "cotización", "tipo de cambio", "noticias", "titulares", "marcador", "quién ganó",
               "bitcoin", "bolsa de valores", "precio del oro"],
        "it": ["prezzo", "prezzi", "quotazione", "tasso di cambio", "notizie", "ultime notizie", "chi ha vinto",
               "risultato della partita", "bitcoin", "borsa"],
        "pt": ["preço", "preços", "cotação", "taxa de câmbio", "notícias", "manchetes", "placar", "quem ganhou",
               "bitcoin", "bolsa de valores"],
        "nl": ["prijs", "koers", "wisselkoers", "nieuws", "uitslag", "wie heeft gewonnen", "bitcoin", "beurs"],
        "hi": ["कीमत", "दाम", "भाव", "खबर", "ख़बर", "समाचार", "स्कोर", "किसने जीता", "बिटकॉइन", "शेयर"],
        "hinglish": ["kitne ka hai", "daam", "bhav kya", "rate kya hai", "khabar", "samachar", "kisne jeeta", "kaun jeeta", "bitcoin"],
        "tr": ["fiyatı", "fiyat", "döviz kuru", "haberler", "son dakika", "skor", "kim kazandı", "bitcoin", "borsa"],
        "ru": ["цена", "стоимость", "курс", "новости", "счёт матча", "кто выиграл", "биткоин"],
        "ar": ["سعر", "أسعار", "أخبار", "نتيجة المباراة", "من فاز", "بيتكوين"],
        "ja": ["価格", "値段", "株価", "為替", "ニュース", "ビットコイン"],
        "ko": ["가격", "주가", "환율", "뉴스", "비트코인"],
        "vi": ["giá", "tỷ giá", "tin tức", "ai thắng", "bitcoin"],
        "uk": ["ціна", "вартість", "курс", "новини", "хто виграв", "біткоїн"],
        "pl": ["cena", "kurs", "wiadomości", "kto wygrał", "bitcoin"],
        "sv": ["pris", "priset", "kurs", "nyheter", "vem vann", "bitcoin"],
        "cs": ["cena", "kurz", "zprávy", "kdo vyhrál", "bitcoin"],
        "nb": ["pris", "prisen", "kurs", "nyheter", "hvem vant", "bitcoin"],
        "da": ["pris", "prisen", "kurs", "nyheder", "hvem vandt", "bitcoin"],
        "bg": ["цена", "курс", "новини", "кой спечели", "биткойн"],
        "fi": ["hinta", "kurssi", "uutiset", "kuka voitti", "bitcoin"],
        "hr": ["cijena", "tečaj", "vijesti", "tko je pobijedio", "bitcoin"],
        "sk": ["cena", "kurz", "správy", "kto vyhral", "bitcoin"],
        "zh": ["价格", "價格", "股价", "股價", "汇率", "匯率", "新闻", "新聞", "比特币"],
        "hu": ["árfolyam", "ára", "hírek", "ki nyert", "bitcoin"],
        "ro": ["preț", "pretul", "prețul", "curs", "știri", "cine a câștigat", "bitcoin"],
        "et": ["hind", "kurss", "uudised", "kes võitis", "bitcoin"]
    ]

    /// Explicit "search the web for …" at the start of a request.
    static let searchVerbs: [String: [String]] = [
        "en": ["search the web for", "search online for", "google", "look up online"],
        "de": ["suche im internet nach", "such im internet nach", "google mal", "suche online nach", "such online nach"],
        "fr": ["cherche sur internet", "recherche sur internet", "cherche en ligne", "recherche en ligne"],
        "es": ["busca en internet", "busca en google", "busca en línea", "buscar en internet"],
        "it": ["cerca su internet", "cerca online", "cerca su google"],
        "pt": ["pesquise na internet", "pesquisa na internet", "procure na internet", "pesquise no google"],
        "nl": ["zoek op internet", "zoek online", "google naar"],
        "hi": ["इंटरनेट पर खोजो", "ऑनलाइन खोजो", "गूगल करो"],
        "hinglish": ["online dhundo", "google karo", "internet pe dhundo", "search karo"]
    ]

    // MARK: Writing (route: write)

    /// Verbs that ask Bibbles to write something, checked near the start.
    static let write: [String: [String]] = [
        "de": ["schreib", "schreibe", "schreiben sie", "verfasse", "formuliere", "entwirf"],
        "fr": ["écris", "écrivez", "écrire", "rédige", "rédigez", "compose"],
        "es": ["escribe", "escríbeme", "escribir", "redacta", "redáctame", "compón"],
        "it": ["scrivi", "scrivimi", "scrivere", "redigi", "componi"],
        "pt": ["escreva", "escreve", "escrever", "redija", "redige"],
        "nl": ["schrijf", "stel een", "maak een mail", "maak een e-mail"],
        "hi": ["लिखो", "लिखिए", "लिखें", "लिख दो"],
        "hinglish": ["likho", "likh do", "likh de", "draft karo", "mail likho", "email likho"],
        "tr": ["yaz", "yazar mısın", "yazın"],
        "ru": ["напиши", "напишите", "составь"],
        "ar": ["اكتب", "اكتبي", "صغ"],
        "ja": ["書いて", "作成して"],
        "ko": ["써줘", "써 줘", "작성해"],
        "vi": ["viết", "soạn"],
        "uk": ["напиши", "напишіть", "склади"],
        "pl": ["napisz", "napiszcie", "zredaguj"],
        "sv": ["skriv"],
        "cs": ["napiš", "napište"],
        "nb": ["skriv"],
        "da": ["skriv"],
        "bg": ["напиши", "напишете"],
        "fi": ["kirjoita"],
        "hr": ["napiši", "napišite"],
        "sk": ["napíš", "napíšte"],
        "zh": ["写一", "寫一", "帮我写", "幫我寫"],
        "hu": ["írj", "írjon", "fogalmazz"],
        "ro": ["scrie", "scrieți", "redactează"],
        "et": ["kirjuta"]
    ]

    // MARK: Editing (route: edit; only when Bibbles wrote something recently)

    /// Commands only ("make it shorter"), never bare comparatives such as
    /// "más corto", which also appear in ordinary questions.
    static let edit: [String: [String]] = [
        "de": ["mach es kürzer", "mach es länger", "mach das kürzer", "mach das länger", "mach es formeller",
               "mach es freundlicher", "mach es lockerer", "ändere das", "ändere es", "schreib es neu", "schreib das neu",
               "schreib es um", "schreib das um", "formuliere es um"],
        "fr": ["rends-le plus court", "rends-la plus courte", "rends-le plus long", "rends-le plus formel",
               "fais-le plus court", "fais-la plus courte", "raccourcis-le", "raccourcis-la", "change-le", "change-la",
               "modifie-le", "modifie-la", "réécris-le", "réécris-la", "reformule-le", "reformule-la"],
        "es": ["hazlo más corto", "hazlo más largo", "hazla más corta", "hazlo más formal", "hazla más formal",
               "acórtalo", "acórtala", "cámbialo", "cámbiala", "reescríbelo", "reescríbela", "escríbelo de nuevo"],
        "it": ["rendilo più corto", "rendila più corta", "rendilo più lungo", "rendilo più formale", "fallo più corto",
               "falla più corta", "accorcialo", "accorciala", "cambialo", "cambiala", "riscrivilo", "riscrivila"],
        "pt": ["deixa mais curto", "deixe mais curto", "deixa mais curta", "deixe mais curta", "torne-o mais curto",
               "torna-o mais curto", "deixe mais formal", "encurte isso", "encurta isso", "muda isso", "mude isso",
               "reescreva isso", "reescreve isso"],
        "nl": ["maak het korter", "maak het langer", "maak het formeler", "verander het", "herschrijf het",
               "schrijf het opnieuw"],
        "hi": ["इसे छोटा करो", "इसे छोटा कर दो", "इसे लंबा करो", "इसे बदल दो", "इसे दोबारा लिखो", "इसे फिर से लिखो"],
        "hinglish": ["isko chhota karo", "isko chota karo", "isko chhota kar do", "isko lamba karo", "isko badal do",
                     "isko phir se likho", "isko dobara likho"],
        "tr": ["kısalt", "daha kısa yap", "yeniden yaz"],
        "ru": ["сделай короче", "сделай длиннее", "перепиши это", "перепиши"],
        "ar": ["اجعله أقصر", "اختصره", "أعد كتابته"],
        "ja": ["短くして", "長くして", "書き直して"],
        "ko": ["짧게 해줘", "길게 해줘", "다시 써줘", "다시 써 줘"],
        "vi": ["viết lại", "viết ngắn lại"],
        "uk": ["зроби коротше", "зроби довше", "перепиши це", "перепиши"],
        "pl": ["skróć to", "zrób to krócej", "przepisz to", "napisz to od nowa"],
        "sv": ["gör den kortare", "gör det kortare", "skriv om den", "skriv om det"],
        "cs": ["zkrať to", "udělej to kratší", "přepiš to"],
        "nb": ["gjør den kortere", "gjør det kortere", "skriv den om", "skriv det om"],
        "da": ["gør den kortere", "gør det kortere", "skriv den om", "skriv det om"],
        "bg": ["направи го по-кратко", "съкрати го", "пренапиши го"],
        "fi": ["lyhennä se", "tee siitä lyhyempi", "kirjoita se uudelleen"],
        "hr": ["skrati to", "napravi to kraće", "prepiši to"],
        "sk": ["skráť to", "urob to kratšie", "prepíš to"],
        "zh": ["改短一点", "缩短一点", "縮短一點", "重写一下", "重寫一下", "再写一遍"],
        "hu": ["rövidítsd le", "legyen rövidebb", "írd át"],
        "ro": ["fă-l mai scurt", "scurtează-l", "rescrie-l"],
        "et": ["tee see lühemaks", "lühenda seda", "kirjuta see ümber"]
    ]

    // MARK: Screen (route: screen)

    static let screen: [String: [String]] = [
        "de": ["auf meinem bildschirm", "auf dem bildschirm", "am bildschirm", "auf meinem screen", "was siehst du",
               "auf meinem monitor"],
        "fr": ["sur mon écran", "sur l'écran", "à l'écran", "ce que tu vois", "qu'est-ce que tu vois"],
        "es": ["en mi pantalla", "en la pantalla", "lo que ves", "qué ves"],
        "it": ["sul mio schermo", "sullo schermo", "cosa vedi", "quello che vedi"],
        "pt": ["na minha tela", "na tela", "no meu ecrã", "no ecrã", "o que você vê", "o que vês"],
        "nl": ["op mijn scherm", "op het scherm", "wat zie je"],
        "hi": ["स्क्रीन पर", "स्क्रीन में", "मेरी स्क्रीन"],
        "hinglish": ["screen pe", "screen par", "screen mein", "meri screen"],
        "tr": ["ekranımda", "ekranda"],
        "ru": ["на экране", "на моём экране", "на моем экране"],
        "ar": ["على شاشتي", "على الشاشة"],
        "ja": ["画面"],
        "ko": ["화면"],
        "vi": ["trên màn hình"],
        "uk": ["на екрані", "на моєму екрані"],
        "pl": ["na ekranie", "na moim ekranie"],
        "sv": ["på skärmen", "på min skärm"],
        "cs": ["na obrazovce"],
        "nb": ["på skjermen"],
        "da": ["på skærmen"],
        "bg": ["на екрана"],
        "fi": ["näytöllä", "ruudulla"],
        "hr": ["na zaslonu", "na ekranu"],
        "sk": ["na obrazovke"],
        "zh": ["屏幕上", "螢幕上", "屏幕", "螢幕"],
        "hu": ["a képernyőn", "képernyőmön"],
        "ro": ["pe ecran", "pe ecranul meu"],
        "et": ["ekraanil"]
    ]

    // MARK: Deep tasks (route: deep)

    /// Requests that ask for genuinely hard work. Long code, stack traces and
    /// maths are detected without words (see `ToolGate.deepScore`).
    static let deep: [String: [String]] = [
        "en": ["step by step", "in depth", "in detail", "prove that", "derive", "debug this", "analyze this",
               "analyse this", "detailed analysis", "review this code"],
        "de": ["schritt für schritt", "ausführlich", "im detail", "beweise", "beweisen sie", "herleiten", "analysiere",
               "detaillierte analyse"],
        "fr": ["étape par étape", "en détail", "démontre", "démontrez", "prouve que", "analyse en détail", "analyse détaillée"],
        "es": ["paso a paso", "en detalle", "demuestra", "demuestre", "analiza en detalle", "análisis detallado"],
        "it": ["passo dopo passo", "passo passo", "in dettaglio", "dimostra", "dimostrare", "analizza in dettaglio"],
        "pt": ["passo a passo", "em detalhe", "demonstre", "prove que", "analise em detalhe", "análise detalhada"],
        "nl": ["stap voor stap", "in detail", "bewijs dat", "analyseer"],
        "hi": ["विस्तार से", "चरण दर चरण", "सिद्ध करो", "सिद्ध कीजिए"],
        "hinglish": ["step by step samjhao", "detail mein", "vistar se", "siddh karo"],
        "tr": ["adım adım", "ayrıntılı", "kanıtla"],
        "ru": ["пошагово", "подробно", "докажи", "проанализируй"],
        "ar": ["خطوة بخطوة", "بالتفصيل", "أثبت"],
        "ja": ["ステップバイステップ", "詳しく", "証明して"],
        "ko": ["단계별로", "자세히", "증명해"],
        "vi": ["từng bước", "chi tiết", "chứng minh"],
        "uk": ["покроково", "детально", "доведи"],
        "pl": ["krok po kroku", "szczegółowo", "udowodnij"],
        "sv": ["steg för steg", "i detalj", "bevisa"],
        "cs": ["krok za krokem", "podrobně", "dokaž"],
        "nb": ["steg for steg", "i detalj", "bevis at"],
        "da": ["trin for trin", "i detaljer", "bevis at"],
        "bg": ["стъпка по стъпка", "подробно", "докажи"],
        "fi": ["vaihe vaiheelta", "yksityiskohtaisesti", "todista"],
        "hr": ["korak po korak", "detaljno", "dokaži"],
        "sk": ["krok za krokom", "podrobne", "dokáž"],
        "zh": ["一步一步", "详细", "詳細", "证明", "證明"],
        "hu": ["lépésről lépésre", "részletesen", "bizonyítsd"],
        "ro": ["pas cu pas", "în detaliu", "demonstrează"],
        "et": ["samm-sammult", "üksikasjalikult", "tõesta"]
    ]

    // MARK: Simple conversation (route: simple)

    static let greeting: [String: [String]] = [
        "en": ["hi", "hello", "hey", "good morning", "good evening", "thanks", "thank you", "how are you"],
        "de": ["hallo", "guten morgen", "guten tag", "guten abend", "danke", "wie geht's", "wie geht es dir"],
        "fr": ["bonjour", "salut", "bonsoir", "merci", "ça va", "comment ça va"],
        "es": ["hola", "buenos días", "buenas tardes", "buenas noches", "gracias", "qué tal", "cómo estás"],
        "it": ["ciao", "buongiorno", "buonasera", "grazie", "come stai"],
        "pt": ["olá", "oi", "bom dia", "boa tarde", "boa noite", "obrigado", "obrigada", "tudo bem"],
        "nl": ["hallo", "hoi", "goedemorgen", "goedenavond", "dank je", "bedankt", "hoe gaat het"],
        "hi": ["नमस्ते", "धन्यवाद", "शुक्रिया", "कैसे हो"],
        "hinglish": ["namaste", "kaise ho", "kya haal hai", "shukriya", "dhanyavaad"],
        "tr": ["merhaba", "günaydın", "teşekkürler", "nasılsın"],
        "ru": ["привет", "здравствуйте", "спасибо", "как дела"],
        "ar": ["مرحبا", "السلام عليكم", "شكرا", "كيف حالك"],
        "ja": ["こんにちは", "おはよう", "ありがとう"],
        "ko": ["안녕하세요", "안녕", "고마워", "감사합니다"],
        "vi": ["xin chào", "cảm ơn"],
        "uk": ["привіт", "дякую", "як справи"],
        "pl": ["cześć", "dzień dobry", "dziękuję", "jak się masz"],
        "sv": ["hej", "god morgon", "tack", "hur mår du"],
        "cs": ["ahoj", "dobrý den", "děkuji", "jak se máš"],
        "nb": ["hei", "god morgen", "takk", "hvordan går det"],
        "da": ["hej", "godmorgen", "tak", "hvordan går det"],
        "bg": ["здравей", "благодаря", "как си"],
        "fi": ["hei", "moi", "kiitos", "mitä kuuluu"],
        "hr": ["bok", "dobar dan", "hvala", "kako si"],
        "sk": ["ahoj", "dobrý deň", "ďakujem", "ako sa máš"],
        "zh": ["你好", "您好", "谢谢", "謝謝"],
        "hu": ["szia", "jó napot", "köszönöm", "hogy vagy"],
        "ro": ["bună", "salut", "mulțumesc", "ce faci"],
        "et": ["tere", "aitäh", "kuidas läheb"]
    ]

    /// Words that point at something unnamed ("this", "that", "here"): such
    /// a short question may be about the screen or a selection, so it is
    /// never treated as a simple question.
    static let deictic: [String: [String]] = [
        "en": ["this", "that", "these", "those", "it", "here", "there"],
        "de": ["das", "dies", "diese", "dieser", "dieses", "hier", "da", "es", "dabei", "damit", "dazu", "davon"],
        "fr": ["ça", "cela", "ceci", "cette", "ici", "celui-ci", "celle-ci"],
        "es": ["esto", "eso", "este", "esta", "aquí", "ahí"],
        "it": ["questo", "questa", "quello", "quella", "qui", "qua", "lì"],
        "pt": ["isso", "isto", "este", "esta", "aqui", "aí"],
        "nl": ["dit", "dat", "deze", "hier", "daar", "het"],
        "hi": ["यह", "ये", "इसे", "इसका", "यहाँ", "वह"],
        "hinglish": ["ye", "yeh", "isko", "iska", "iske", "yahan", "woh", "wo"],
        "ru": ["это", "этот", "здесь", "тут"], "uk": ["це", "цей", "тут"],
        "pl": ["to", "ten", "tutaj"], "tr": ["bu", "şu", "burada"],
        "ja": ["これ", "それ", "ここ"], "ko": ["이거", "이것", "여기"], "zh": ["这个", "這個", "这里", "這裡"]
    ]

    /// Question words: a short request that starts with one is a question.
    static let questionWords: [String: [String]] = [
        "en": ["what", "who", "why", "how", "when", "where", "which", "is", "are", "can", "does", "do", "define", "explain", "tell me"],
        "de": ["was", "wer", "warum", "wieso", "wie", "wann", "wo", "welche", "welcher", "ist", "kannst", "erkläre", "erklär"],
        "fr": ["qu'est-ce", "que", "qui", "pourquoi", "comment", "quand", "où", "quel", "quelle", "est-ce", "explique"],
        "es": ["qué", "que", "quién", "por qué", "cómo", "cuándo", "dónde", "cuál", "explica", "explícame"],
        "it": ["cosa", "che", "chi", "perché", "come", "quando", "dove", "quale", "spiega", "spiegami"],
        "pt": ["o que", "quem", "por que", "porque", "como", "quando", "onde", "qual", "explique", "explica"],
        "nl": ["wat", "wie", "waarom", "hoe", "wanneer", "waar", "welke", "leg uit"],
        "hi": ["क्या", "कौन", "क्यों", "कैसे", "कब", "कहाँ", "समझाओ"],
        "hinglish": ["kya", "kaun", "kyun", "kyu", "kaise", "kab", "kahan", "samjhao", "batao"]
    ]

    /// Common words of Hindi written in Latin letters. Two of these (or one
    /// strong one) mark a message as Hinglish.
    static let hinglishMarkers: Set<String> = [
        "hai", "hain", "kya", "kar", "karo", "kardo", "mujhe", "mera", "meri", "mere", "nahi", "nahin", "kaise",
        "kyun", "kyu", "batao", "bata", "yaar", "accha", "acha", "theek", "thik", "isko", "usko", "iska", "kitna",
        "kitne", "kahan", "chahiye", "wala", "wali", "matlab", "abhi", "aaj", "hoga", "raha", "rahi", "likho", "samjhao"
    ]
    static let strongHinglishMarkers: Set<String> = [
        "karo", "kardo", "batao", "mujhe", "chahiye", "isko", "samjhao", "likho", "kaise", "nahi", "kitne"
    ]
}

/// The few words Bibbles says itself on the fast local paths (time, date,
/// weather), per language. English is the fallback. UI translation of the
/// rest of Bibbles is out of scope; new user-facing strings live here.
enum ToolGateStrings {
    // Developer menu (English only; developer-facing).
    static let menuGate = "Tool Gate"
    static let menuRecordLog = "Record Tool Gate Log"
    static let menuCopyLog = "Copy Tool Gate Log"
    static let menuClearLog = "Clear Tool Gate Log"
    static let logCopied = "Tool Gate log copied"
    static let logEmpty = "The Tool Gate log is empty. Turn on Record Tool Gate Log first."

    // Settings → Dictation
    static let speechLanguageTitle = "I speak"
    static let speechLanguageDetail = "The language you dictate and ask in. Auto works for mixed languages, a fixed choice is more accurate."
    static let speechLanguageAuto = "Detect automatically"

    /// "It's 3:45 PM." / "Es ist 15:45."
    static func localTime(_ time: String, zone: String, language: String) -> String {
        switch language {
        case "de": return "Es ist \(time)."
        case "fr": return "Il est \(time)."
        case "es": return "Son las \(time)."
        case "it": return "Sono le \(time)."
        case "pt": return "São \(time)."
        case "nl": return "Het is \(time)."
        case "hi": return "अभी \(time) हैं।"
        default: return "It's \(time) \(zone)."
        }
    }

    /// "It's 3:45 PM on Monday in Tokyo (GMT+9)."
    static func placeTime(_ time: String, day: String, place: String, zone: String, language: String) -> String {
        switch language {
        case "de": return "In \(place) ist es \(time) (\(day), \(zone))."
        case "fr": return "À \(place), il est \(time) (\(day), \(zone))."
        case "es": return "En \(place) son las \(time) (\(day), \(zone))."
        case "it": return "A \(place) sono le \(time) (\(day), \(zone))."
        case "pt": return "Em \(place) são \(time) (\(day), \(zone))."
        case "nl": return "In \(place) is het \(time) (\(day), \(zone))."
        case "hi": return "\(place) में अभी \(time) हैं (\(day), \(zone))।"
        default: return "It's \(time) on \(day) in \(place) (\(zone))."
        }
    }

    static func today(_ date: String, language: String) -> String {
        switch language {
        case "de": return "Heute ist \(date)."
        case "fr": return "Nous sommes le \(date)."
        case "es": return "Hoy es \(date)."
        case "it": return "Oggi è \(date)."
        case "pt": return "Hoje é \(date)."
        case "nl": return "Vandaag is het \(date)."
        case "hi": return "आज \(date) है।"
        default: return "It's \(date)."
        }
    }

    /// Languages with their own weather sentences; others use English.
    static let weatherLanguages: Set<String> = ["de", "fr", "es", "it", "pt", "nl"]

    static func weatherNow(place: String, now: String, condition: String?, language: String) -> String {
        let sky = condition.map { ", \($0)" } ?? ""
        switch language {
        case "de": return "Aktuell in \(place): \(now)\(sky)."
        case "fr": return "En ce moment à \(place) : \(now)\(sky)."
        case "es": return "Ahora en \(place): \(now)\(sky)."
        case "it": return "Ora a \(place): \(now)\(sky)."
        case "pt": return "Agora em \(place): \(now)\(sky)."
        case "nl": return "Nu in \(place): \(now)\(sky)."
        default: return "Right now in \(place): \(now)\(sky)."
        }
    }

    static func weatherRange(low: String, high: String, rain: Int?, tomorrow: Bool, place: String,
                             condition: String?, language: String) -> String {
        let sky = condition.map { ", \($0)" } ?? ""
        func chance(_ word: String) -> String { rain.map { ", \(word) \($0) %" } ?? "" }
        switch language {
        case "de": return (tomorrow ? "Morgen in \(place): " : "Heute: ") + "\(low) bis \(high)\(sky)\(chance("Regenwahrscheinlichkeit"))."
        case "fr": return (tomorrow ? "Demain à \(place) : " : "Aujourd'hui : ") + "\(low) à \(high)\(sky)\(chance("risque de pluie"))."
        case "es": return (tomorrow ? "Mañana en \(place): " : "Hoy: ") + "de \(low) a \(high)\(sky)\(chance("probabilidad de lluvia"))."
        case "it": return (tomorrow ? "Domani a \(place): " : "Oggi: ") + "da \(low) a \(high)\(sky)\(chance("probabilità di pioggia"))."
        case "pt": return (tomorrow ? "Amanhã em \(place): " : "Hoje: ") + "de \(low) a \(high)\(sky)\(chance("chance de chuva"))."
        case "nl": return (tomorrow ? "Morgen in \(place): " : "Vandaag: ") + "\(low) tot \(high)\(sky)\(chance("kans op regen"))."
        default: return (tomorrow ? "Tomorrow in \(place): " : "Today: ") + "\(low) to \(high)\(sky)\(chance("chance of rain"))."
        }
    }

    /// WMO weather codes in plain words, per language.
    static func condition(_ code: Int, language: String) -> String {
        let group: Int
        switch code {
        case 0: group = 0
        case 1: group = 1
        case 2: group = 2
        case 3: group = 3
        case 45, 48: group = 4
        case 51, 53, 55, 56, 57: group = 5
        case 61, 63, 66, 67, 80, 81: group = 6
        case 65, 82: group = 7
        case 71, 73, 75, 77, 85, 86: group = 8
        case 95, 96, 99: group = 9
        default: group = 10
        }
        let words: [String: [String]] = [
            "de": ["klar", "überwiegend klar", "teils bewölkt", "bewölkt", "neblig", "Nieselregen", "Regen", "starker Regen", "Schnee", "Gewitter", "wechselhaft"],
            "fr": ["ciel dégagé", "plutôt dégagé", "partiellement nuageux", "nuageux", "brouillard", "bruine", "pluie", "forte pluie", "neige", "orages", "temps variable"],
            "es": ["despejado", "mayormente despejado", "parcialmente nublado", "nublado", "niebla", "llovizna", "lluvia", "lluvia fuerte", "nieve", "tormentas", "tiempo variable"],
            "it": ["sereno", "per lo più sereno", "parzialmente nuvoloso", "nuvoloso", "nebbia", "pioviggine", "pioggia", "pioggia forte", "neve", "temporali", "tempo variabile"],
            "pt": ["céu limpo", "predominantemente limpo", "parcialmente nublado", "nublado", "neblina", "garoa", "chuva", "chuva forte", "neve", "trovoadas", "tempo variável"],
            "nl": ["helder", "overwegend helder", "half bewolkt", "bewolkt", "mist", "motregen", "regen", "zware regen", "sneeuw", "onweer", "wisselvallig"]
        ]
        return words[language]?[group] ?? LiveWeather.condition(code)
    }
}
