# Files agent: manual test sheet

Developer builds only (`DEVELOPER=1 ./scripts/build-dev-app.sh`).

**Before you start:** turn on **Settings → Developer → Local mode** and **AI Agents (Files)**. Save your OpenRouter and Anthropic keys and press **Test** on each. Then turn on **Record Tool Gate Log**.

Test on a **copy**. Make a folder of sample files, then point Desktop or Downloads at it, or move the samples in for the test. Never test on files you can't lose. Every run must show a preview and wait for **Start**. Nothing may change before you press it.

For each test, ask by voice (hold Control + Option) or by typing (double-tap Control). Note pass or fail, and copy the Tool Gate log at the end. The log holds no file names and none of your words.

| # | Request (language) | Sample files | Expected preview | After Start | After Undo |
|---|---|---|---|---|---|
| 1 | "Clean up my Downloads folder" (EN) | 10 PDFs, 10 PNGs, 3 ZIPs, 2 DMGs | Several folders by type (for example PDFs, Images, Archives). Moves only, **no Trash** line. | Files in the new folders. The summary says how many files went into how many folders. | All files back at the top level. The new folders are gone. |
| 2 | "Put all PDFs on my Desktop into a folder called Documents 2026" (EN) | 5 PDFs + 3 other files on the Desktop | "Create 1 folder · Move 5 files". Only PDFs are listed. | The 5 PDFs are in "Documents 2026". The other files stay. | PDFs back. The folder is removed. |
| 3 | "Organize my screenshots by month" (EN) | 6 "Screenshot …" PNGs from 2 different months | Folders like `Screenshots/2026-09`, `Screenshots/2026-10`. | Each screenshot is in the folder for its month. | All back. Empty month folders are removed. |
| 4 | "Move old .dmg installers in Downloads to the Trash" (EN) | 2 DMGs added over 30 days ago, 1 new DMG | "Move 2 files to Trash", with the Trash lines highlighted red. The new DMG isn't listed. | The 2 old DMGs are in the Trash (Finder → Trash). Nothing is permanently deleted. | Both DMGs come back out of the Trash to their old place. |
| 5 | "Limpia mi carpeta de descargas" (ES) | Same as #1 | The preview line is in Spanish ("Crear … carpetas · Mover … archivos"). | The summary is in Spanish. | "Deshecho. Todo volvió a su lugar." |
| 6 | "Räum meinen Download-Ordner auf" (DE) | Same as #1 | German preview. No Trash. | German summary. Spoken in German if Speak Answers Aloud is on. | Everything restored. |
| 7 | "Downloads folder saaf kar do" (Hinglish) | Same as #1 | English wording, moves only. | English summary. | Everything restored. |
| 8 | "Range mes captures d'écran par mois sur le bureau" (FR) | Screenshots on the Desktop | French preview with month folders. | French summary. | Restored. |
| 9 | "デスクトップのPDFを全部「請求書」フォルダに移動して" (JA) | PDFs on the Desktop | Japanese preview: 「フォルダを1個作成 · ファイルを…個移動」 | Japanese summary. | Restored. |
| 10 | "Clean up my Downloads folder", then **Stop** during the run (EN) | 300+ small files | Preview, then Start. | Progress shows "Moving files… N of M". After Stop, the current file finishes and the run halts. The summary says "Stopped after N of M." | Undo puts back exactly the files that moved. |
| 11 | "Organize my Downloads" when a file with the same name already exists in the destination (EN) | `PDFs/report.pdf` already there, plus a new `report.pdf` at the top level | The new file is listed as moving to PDFs. | The new file becomes `report 2.pdf`. **Nothing is overwritten.** | `report 2.pdf` goes back as `report.pdf`. The existing one is untouched. |
| 12 | "Clean up my Downloads" with a hidden file, an `.app` and a symlink to another folder (EN) | `.secret`, `Some.app`, a link to `~/Pictures` | None of the three appears in the preview. | None of them is moved. | — |
| 13 | "Delete everything in Downloads" (EN) | Any files | If anything is planned, it is **only** Trash lines. There is never a permanent delete. You can Cancel. | (Press Cancel) Nothing changed. | — |
| 14 | "How do I organise my desktop?" (EN) | — | **No agent.** You get an ordinary answer (today's behaviour). | — | — |
| 15 | Turn **AI Agents (Files)** off, then "Clean up my Downloads folder" (EN) | — | **No agent card.** Today's behaviour (the single-file action / command path). | — | — |

## Also check

- **Undo from history:** finish a run, close the card, open the task history at the notch and click the run. The Done · Undo card opens. The menu also shows **Undo Last Agent Task** for 30 minutes.
- **Permission:** in System Settings → Privacy & Security → Files and Folders, turn off Bibbles' access to Downloads, then run #1. The card names the exact setting to turn on.
- **Too big:** a folder with more than 1,000 items asks you to narrow the request. Nothing is scanned further.
- **No server:** with Local mode on, no request goes to `bibbles-api` (check with a proxy such as Proxyman). The planner request goes to OpenRouter or Anthropic and contains only the request and the folder **summary**. No file contents are sent.
- **Labels:** the card header says "Agent Task" in the user's language. No model name is shown anywhere outside Settings → Developer.

---

# Screen agent: manual test sheet

**Before you start:**
1. Turn on **Settings → Developer → AI Agents (Screen)**. Requests other than "fill … with my details" also need **Local mode** and your OpenRouter key.
2. In **My details**, press **Use my Contacts card**. macOS asks for Contacts access once. Check the fields, then press **Save**.
3. Bibbles Dev needs **Accessibility** permission.

| # | Where | Say or type | Expected |
|---|---|---|---|
| S1 | Safari or Chrome, any sign-up form (for example a newsletter or test-account page) | "Fill in this sign-up form with my details" | The card says **ON THIS MAC · NO AI**. The preview lists "Type “Mohit” into “First name”" and so on. Passwords and card fields are never listed. Start fills them. **Sign up is NOT pressed.** The summary says to press it yourself. |
| S2 | The same form | Press **Undo** | The typed fields are empty again. |
| S3 | TextEdit or Pages with a document open | "Click Export and save it as a PDF" | Preview: "Choose File ▸ Export as PDF…", then "Press “Save”", marked "no undo". Start opens the save sheet and presses Save. The PDF appears next to the document. |
| S4 | Anywhere | "Go to Settings and turn on dark mode" | Preview: one step, turn dark mode on. Start switches dark mode on. Undo switches it back. |
| S5 | A form with "Remember me" ticked | "Untick remember me" | Preview: "Turn off “Remember me”". Start unticks it. |
| S6 | A checkout page | "Fill my details and pay" | The details are filled. **Pay** is skipped with "Bibbles never presses …". |
| S6b | Preview with an image | "Can you please export this to PDF and save it on my Desktop" | Preview: "Choose File ▸ Export as PDF…", then "Save in Desktop". Done shows "Saved holi7.pdf in Desktop" and a **Show in Finder** button. |
| S6c | TextEdit with a document | "Export this as PDF into my Holi folder and name it holi final" | "Save as “holi final” in Desktop ▸ Holi" (or wherever your Holi folder is). If the folder doesn't exist, the step is skipped unless you said "new folder". |
| S6d | Repeat S6b | — | macOS asks to **Replace** the existing file. Bibbles stops with "a file with that name already exists". You choose. |
| S7 | Anywhere | "Where is the Export button?" | **No agent.** Ordinary screen help points at it. |
| S8 | Turn **AI Agents (Screen)** off and repeat S1 | — | No agent card. Today's form fill runs, using placeholders like [Your Name]. |

**Privacy check:** with a proxy such as Proxyman, S1 sends **no request at all**. S3 sends one planner request with menu and button titles and field labels only. It never contains your details or what is typed in the fields.

## Screen agent: acting on screen (clicks, typing, music, several parts)

Needs **Screen Recording** permission for Bibbles Dev, so the planner can see the screen and click on it.

| # | Where | Say | Expected |
|---|---|---|---|
| A1 | A piano website in Safari or Chrome (for example a virtual piano page) | "Make up a happy theme tune and play it on this piano" | Preview: "Play 32 notes (about 12 s)". Start: the keys are clicked in rhythm. Stop halts at once. |
| A2 | Mail, with a message open | "Reply saying I'll join at 5 and send it" | Part 1 previews the clicks and the typed text, then waits for Start. Before Send: **"Press Send in Mail?"**. Choose Stop to check that nothing is sent. |
| A3 | Messages, with a conversation open | "Tell Sam I'm on my way" | Preview: type the text, then "Press return (asks you first)". The message is sent only after you confirm. |
| A4 | Safari | "Search the web for Holi festival 2026 and open the first result" | Part 1: click the address bar, type, Return. "Looking again…". Part 2: click the first result. |
| A5 | Any app | A request that would need **Empty Trash** or **Log Out** | That step is skipped with "Bibbles never presses …". |
| A6 | A drum website (keys or clickable pads) | "Play a rock beat on these drums" | Preview: "Play N notes with chords (about N s)". Kick and hi-hat land together. On key-based sites they're exact; on click-only sites they're a few ms apart. |
| A7 | A virtual guitar website | "Strum a happy chord progression on this guitar" | Preview mentions "strums". The pointer drags across the strings while each chord is held. |
| A8 | Any app with a slider (for example System Settings → Sound) | "Drag the volume slider to the middle" | Preview: "Drag “…”". It drags only after Start. |
