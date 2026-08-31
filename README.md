# elixness

Un premier job de **harness** : traduire les `@moduledoc` français d'un projet
Elixir en anglais en lançant des agents Jido.

Ce POC répond à une question d'archi : **pour faire N choses (traduire N
fichiers), vaut-il mieux N process en parallèle, ou 1 process qui enchaîne ?**
Il compare aussi le pipeline nu (elixness) au coding agent complet (Hermes).

## Build

```sh
mix deps.get
mix escript.build     # → ./elixness
```

## Usage

Depuis la racine du projet cible (ex. `~/git/inductive`) :

```sh
elixness translate [--limit N] [--concurrency N] [--dry-run] [--apply] [--model M]
elixness help
```

- `--limit N` : nombre de moduledoc FR à traiter (défaut 10).
- `--concurrency N` : nombre d'agents Jido dans le pool (défaut 10).
  `--concurrency 1` = 1 agent fait les N jobs en séquence.
- `--loop` (défaut) : mode agent loop — le modèle décide d'appeler
  `read_file`/`write_file`/`search_files` et le loop exécute et rejoue
  jusqu'à la réponse finale. C'est le moteur du harness (test G).
- `--no-loop` : appel direct en 1 turn (comportement des tests A/B/E).
- `--dry-run` : découvre + estime les tokens, **aucun appel LLM**.
- sans `--apply` : traduit et affiche le rapport, **rien n'est écrit**.
- `--apply` : écrit les traductions → review avec `git diff`.

## LLM

- Endpoint : **Nous Portal** (`https://inference-api.nousresearch.com/v1`),
  compte Hermes. Token OAuth lu dans `~/.hermes/auth.json`
  (surchargeable via `ELIXNESS_AUTH_PATH`).
- Modèle : `deepseek/deepseek-v4-flash` (surchargeable via `ELIXNESS_MODEL`
  ou `--model`).

## Archi (les 4 étapes du flatmap)

1. **Discover** (mécanique, zéro LLM) — scanne `lib/**/*.ex`, parse les
   `@moduledoc` via `Code.string_to_quoted` (AST), garde N docs qui sentent le
   français, estime les tokens (chars/4 + instruction).
2. **Map** (Jido) — worker pool de `concurrency` agents `Translator`, un signal
   `translate` par doc. Chaque agent fait **un** appel LLM et range le résultat
   dans `state.result`. L'échec LLM n'abat pas l'agent (isolé dans la fiche).
3. **Reduce** — collecte, agrège les tokens (prompt/completion/total, depuis
   `usage` de l'API), mesure temps mural vs somme des latences
   (proxy du séquentiel → facteur de parallélisme).
4. **Apply** — remplacement ligne-par-ligne guidé par l'AST (line + delimiter),
   heredoc préservé, indentation conservée. `git diff` à reviewer.

## L'expérience : 10 process vs 1 process (elixness vs Hermes)

Même jeu de 10 moduledoc FR, même modèle, quatre configurations. Mesuré le
2026-08-27 sur `~/git/inductive`.

### Config

| Paramètre | A — elixness 10 | B — elixness 1 | C — Hermes 10 | D — Hermes 1 |
|---|---|---|---|---|
| moteur | elixness (Jido) | elixness (Jido) | coding agent Hermes | coding agent Hermes |
| agents | 10 | 1 | 10 | 1 |
| jobs/agent | 1 | 10 | 1 | 10 |
| modèle | `deepseek-v4-flash` | idem | idem | idem |
| reasoning | n/a (prompt nu) | n/a | **medium** | **medium** |
| endpoint | Nous Portal | idem | idem | idem |

### Résultats

| Métrique | A — elixness 10 | B — elixness 1 | C — Hermes 10 | D — Hermes 1 |
|---|---|---|---|---|
| temps mural | 44.3 s | 381.3 s | **42 s** | **81 s** |
| tokens total | 22 833 | 61 558 | ~82k in + 9.3k out* | ~30k in + 10.7k out* |
| coût estimé | — | — | **~0.019 $** | **~0.005 $** |
| réussites | 10/10 | 10/10 | 10/10 | 10/10 |
| structure doc | aplatie (1 ligne) | aplatie (1 ligne) | **préservée** | **préservée** |

\* tokens Hermes relevés dans la table `sessions` du store (input/output +
cache-read). Le cache fait le gros du travail : ~750k tokens cache-read pour C
(les 10 agents partagent le system prompt → input quasi gratuit).

### Remarques par test

**A — elixness, 10 process (44.3s)**
- Le parallélisme paie : ~3.4x vs la somme des latences (149.5s), même si
  l'API Nous bride la concurrence réelle.
- Coût identique par job (le parallélisme n'achète que du temps).
- **Qualité : mauvaise.** Le modèle nu aplatit chaque moduledoc sur une seule
  ligne (paragraphes et listes perdus) malgré l'instruction. Le heredoc et les
  backticks sont préservés, mais le rendu est illisible. C'est le comportement
  de deepseek-v4-flash en appel nu, sans le shaping du coding agent.

**B — elixness, 1 process (381.3s)**
- 1 agent enchaîne les 10 : ~8.6x plus lent que A. Sans surprise.
- **Grande variance de latence/tokens** : 2 jobs ont pris ~100s et 15-16k
  tokens (coups de "réflexion" du modèle), contre 7-37s pour les autres. Le
  modèle est imprévisible — en séquentiel, un seul job lent bloque tout.
- Même défaut de qualité que A (aplatissement), plus le coût en temps.

**C — Hermes, 10 agents × 1 fichier (42s)**
- Aussi rapide que A, mais **qualité nettement meilleure** : le coding agent
  préserve les paragraphes, les listes, le markdown, la structure (sections
  `## Model`, bullets `-`).
- Traductions fidèles et idiomatiques (ex. « le départage s'est joué sur une
  entrée dégradée » → "The tie-break was decided on a degraded entry").
- Les identifiants du domaine (`famille`, `temoignage_id`, `agissements`) sont
  conservés tels quels — cohérent avec le code, pas francisés à tort.
- **Bizarre/intrigant** : la 10e traduction (csv_parser) est impeccable et
  concise ; la 5e (analyse_inductive) garde les em-dashes et le style FR
  transposé. Chaque agent Hermes a son propre "style" — il n'y a pas
  d'harmonisation entre les 10 (normal, 10 contextes isolés).

**D — Hermes, 1 agent × 10 fichiers (81s)**
- **Presque 2x plus lent que C** (81 vs 42s) : l'agent séquentiel garde tout
  le contexte des 10 fichiers dans sa fenêtre, donc un prompt plus gros par
  fichier.
- Qualité globalement bonne, mais **une régression visible vs C** : le
  moduledoc `ner_bahaviour` garde « témoignage » en français dans la prose
  ("a raw témoignage") alors que C le traduit. Le contexte chargé (10 fichiers)
  dilue la vigilance linguistique.
- **Excellent** : `attribute_roles` et `categorize` sont traduits avec une
  précision remarquable, y compris les raisonnements les plus délicats (le
  tie-break entre modèles).
- **Bizarre** : `csv_parser` laisse « Format du `content` » en français dans
  une section (résidu de chaîne, pas un identifiant) — le même fichier était
  parfait en C. Incohérence d'un run à l'autre et entre les 2 agents.

### Lecture générale

- **Le parallélisme paie, surtout côté Hermes** : C (42s) est 2x plus rapide
  que D (81s), et la qualité y est plus homogène (1 fichier = 1 focus).
- **Le coding agent (Hermes) > pipeline nu (elixness)** : même modèle, la
  qualité de structure est sans commune mesure. Le system prompt du harness
  fait la différence — c'est le "malloc" bien investi de context-engineering.
- **Le coût n'est pas un obstacle** : C coûte ~0.019 $ pour 10 fichiers (le
  cache-read neutralise le system prompt partagé entre les 10 agents), D
  ~0.005 $. À l'échelle des 71 moduledoc FR d'inductive : ~0.13 $ avec le
  pattern C. La qualité du coding agent n'a pas de surcoût significatif.
- **La variance du modèle est le vrai ennemi** : en séquentiel, un job lent
  (15k tokens, 100s) bloque tout le run. En parallèle, il ne coûte qu'à
  lui-même.
- **Les résidus de français** (témoignage, Format du content) apparaissent
  quand le contexte est chargé (D) — la vigilance linguistique est meilleure
  avec un fichier par agent.

## Test E : elixness + system prompt de Hermes

Pour isoler l'effet du system prompt (vs le loop complet du coding agent),
on a injecté le system prompt réel de Hermes (50 222 chars ≈ 12.5k tokens,
extrait de la table `sessions` du store, sans les tool schemas — Hermes les
envoie dans le champ `tools` du payload, pas dans le prompt) comme system
prompt d'elixness, via `ELIXNESS_SYSTEM_PROMPT`. Elixness lit maintenant
aussi `reasoning` / `completion_tokens_details.reasoning_tokens` / `usage.cost`.

| Métrique | A — elixness nu | E — elixness + prompt Hermes | C — Hermes complet |
|---|---|---|---|
| completion | 18 626 | 14 637 | 8 726 |
| dont reasoning | ? (mélangé) | 13 502 (92%) | 4 574 (52%) |
| réponse utile | ? | 1 135 | 4 152 |
| coût | ~0.05-0.1 $ | **~0.0005 $** | ~0.015 $ |
| temps mural | 44.3 s | 35.6 s | 42 s |
| réussites | 10/10 | 10/10 | 10/10 |

**Ce que ça prouve :**
- Le system prompt de Hermes est responsable de l'essentiel de l'effet :
  il **sépare le raisonnement** de la réponse (92% de l'output d'E est du
  raisonnement compté à part, invisible dans A) et **réduit l'output**.
- **La réponse utile est minuscule (1 135 tokens)** : le modèle réfléchit
  énormément (13.5k tokens de pensées pour 10 traductions) — c'est la
  « réflexion » qui coûte en output, pas la traduction.
- **Le coût d'E est le plus bas de tous (~$0.0005)** : le raisonnement
  compté à part est facturé moins cher, et le gros prompt passe en partie
  par le cache-read.
- **Mais E n'égale pas C en qualité** : C produit 4 152 tokens utiles
  (traductions riches et structurées), E seulement 1 135 (réponses plus
  courtes). Le **loop Hermes** (turns, outils, formatage de la réponse
  finale) apporte la richesse de la réponse, pas l'économie.
- Conclusion : **le system prompt fait l'économie d'output** (séparation du
  raisonnement), **le loop apporte la qualité finale**. Les deux sont
  nécessaires pour égaler C.

## Test F : elixness multi-turn (lire → traduire)

Pour tester si le multi-turn (le loop) suffit à égaler C, on a ajouté
`--multiturn` à elixness : il lit le fichier complet (comme `read_file`) et
demande de traduire le `@moduledoc` qu'il contient, avec le system prompt
Hermes. 10 moduledoc, concurrency 10.

| Métrique | E — 1 appel | F — multi-turn | C — Hermes complet |
|---|---|---|---|
| completion | 14 637 | 15 658 | 8 726 |
| dont reasoning | 13 502 (92%) | 14 188 (91%) | 4 574 (52%) |
| réponse utile | 1 135 | 1 470 | 4 152 |
| coût | ~0.0005 $ | ~0.0005 $ | ~0.015 $ |
| temps mural | 35.6 s | **24.1 s** | 42 s |
| réussites | 10/10 | 10/10 | 10/10 |

**Résultat : le multi-turn ne change presque rien.**
- L'output reste dominé par le raisonnement (91%) et la réponse utile ne
  bouge pas (1 470 vs 1 135 — toujours ~3x moins que C).
- La qualité réelle est inchangée : la traduction est toujours aplatie sur
  une ligne (le modèle refuse de garder les sauts de ligne en appel direct),
  avec parfois un artefact (` ``` ` parasite).
- Seul gain : le temps mural (24.1s, le plus rapide de tous) — le contexte
  fichier complet aide le modèle à répondre plus vite.

**Conclusion** : le multi-turn seul ne suffit pas à égaler C. La différence
de qualité (structure, paragraphes, richesse) ne vient ni du system prompt
(E), ni du multi-turn (F), ni des tools (2-3 utilisés) — elle vient du
**harness complet de Hermes** : son agent loop avec gestion des réponses,
le formatage final, et le comportement de l'API quand elle reçoit des
requêtes multi-turn du coding agent. C'est l'effet « harness » entier, pas
un composant isolé.

## Test G : elixness avec le moteur (agent loop) — LE résultat

On a codé le moteur manquant : **Elixness.Loop** (l'agent loop). Le modèle
décide à chaque turn (appeler un tool ou répondre), le loop exécute les
tool_calls (`read_file`, `write_file`, `search_files` — les 3 outils que
les agents C utilisent) et rejoue jusqu'à la réponse finale. Combiné au
system prompt Hermes via `--loop`.

| Métrique | E — 1 appel | F — multi-turn | G — LOOP | C — Hermes complet |
|---|---|---|---|---|
| completion | 14 637 | 15 658 | 9 494 | 8 726 |
| dont reasoning | 13 502 (92%) | 14 188 (91%) | 5 253 (55%) | 4 574 (52%) |
| réponse utile | 1 135 | 1 470 | 4 241 | 4 152 |
| coût | ~0.0005 $ | ~0.0005 $ | ~0.0015 $ | ~0.015 $ |
| temps mural | 35.6 s | 24.1 s | **23.1 s** | 42 s |
| réussites | 10/10 | 10/10 | 10/10 | 10/10 |
| structure | aplatie | aplatie | **préservée** | préservée |

**Le loop change TOUT.** La réponse utile passe de 1 135 → 4 241 tokens
(≈ C), le reasoning redescend à 55% de l'output (≈ C), et surtout **la
qualité est enfin préservée** : paragraphes, listes, markdown — les
traductions G sont structurellement identiques à celles de C (comparées
fichier par fichier).

**Le coût** (~$0.0015) reste ~10x moins cher que C, avec le temps mural le
plus rapide (23.1s). Le moteur elixness (loop + tools + prompt Hermes)
atteint la qualité d'un coding agent complet à une fraction du coût.

**La leçon finale** : la qualité d'un coding agent vient du **moteur** (le
loop qui exécute les décisions du modèle), pas du prompt seul ni des tools
seuls. Le system prompt + le loop + les tools = le harness. Elixness a
maintenant les trois.

## Test H : le loop amélioré (patterns opencode)

Les 3 améliorations d'opencode intégrées au loop (`Elixness.Loop`) :
1. **Sortie par `finish_reason`** : ne sort que si finish ≠ "tool_calls" ET
   plus de tool_calls en attente (robuste si l'API coupe en plein tool call).
2. **MAX_STEPS_PROMPT** : à la limite d'itérations, le modèle est forcé de
   résumer et arrêter (réponse utile) au lieu d'un échec sec.
3. **Condition de sortie complète** : le dernier assistant doit être
   rattaché au dernier user message (pas de sortie sur message orphelin).

| Métrique | G — loop v1 | H — loop opencode |
|---|---|---|
| completion | 9 494 | **8 157** |
| reasoning | 5 253 | **3 931** |
| coût | ~0.0015 $ | ~0.0015 $ |
| temps mural | 23.1 s | **21.2 s** |
| réussites | 10/10 | 10/10 |
| turns/agent | 3 | 3 |
| structure | préservée | préservée |

**Résultat** : le loop amélioré est légèrement plus efficace (completion
8 157 vs 9 494, reasoning 3 931 vs 5 253 — le modèle « réfléchit » moins,
les sorties sont plus directes grâce au finish_reason) et plus rapide
(21.2s vs 23.1s). La qualité reste identique (structure préservée, diff
minime vs C). Les améliorations d'opencode apportent de la robustesse sans
rien perdre en qualité.

## L'inbox — branchée au CLI

`Elixness.Inbox` (le pattern next-turn/next-step de deepseek-harness sur
GenServer) est intégrée au loop ET branchée au CLI :

- API : `followup` (prochain turn, réveille), `steer` (prochain step,
  réveille), `inject` (prochain step, sans réveiller), `drain` (le loop
  l'appelle à chaque turn).
- **CLI** : chaque job crée son inbox et la passe au loop via le signal.
  Le loop draine à chaque turn → n'importe qui peut injecter un message en
  cours de traduction.
- **Testé** : steering validé en conditions réelles (message injecté pendant
  le loop, vu par le modèle au turn suivant — « Steered as requested »).
- **Limite actuelle** : les inbox sont internes aux jobs (pas de registre
  externe). Le steering externe (commande `elixness steer <fichier> <msg>`)
  demandera un registre ETS keyé par fichier — prochaine brique.

## Le Registry — la fondation du chat

`Elixness.InboxRegistry` : un `Registry` (ETS avec cycle de vie) qui associe
`fichier → inbox_pid` pour chaque job en cours. Démarre au boot du CLI, et
chaque job enregistre son inbox.

**Testé (même VM — le futur chat)** : un process « chat » retrouve le job via
`Registry.lookup/1`, injecte un message, et le modèle l'intègre au turn
suivant (« Done. ... STEERED. »).

**Limite découverte** : un escript est un process isolé — le Registry n'est
pas partagé entre deux invocations `elixness` séparées. Le steering
inter-process exige un **process long-lived** (le futur chat/daemon) qui tient
le Registry ET les jobs dans la même VM. C'est cohérent avec la décision
« elixness est le chat » : le chat sera un process persistant.

## Le chat — première version (2026-08-27)

`elixness chat` : la boucle de conversation avec le malloc visible.

- **`Elixness.Context`** : assemble ce qui part au LLM (system + fichiers +
  conversation + tools) et estime les tokens par section (chars/4). C'est la
  transparence — on voit ce qu'on envoie avant d'envoyer.
- **`Context.flamegraph/1`** : le breakdown visuel (le flamegraph de
  context-engineering rendu vivant) :
  ```
  system             179 tok  ████████████████████████████████████████
  files                0 tok  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  conversation       111 tok  ███████████████░░░░░░░░░░░░░░░░░░░░░░░░░
  tools                0 tok  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  TOTAL               290 / 128000
  ```
- **`Elixness.Chat`** : boucle `IO.gets` → assemble → envoie au loop
  (conversation complète via le nouveau paramètre `messages` de
  `Loop.run/7`) → affiche la réponse + usage réel → répète. Commandes :
  `/quit`, `/files`.
- Le loop accepte maintenant une conversation complète en entrée
  (`Loop.run/7` avec `messages`) — la brique du chat.

**Testé** : `echo "Bonjour" | elixness chat` → flamegraph affiché, réponse
du modèle, flamegraph mis à jour (conversation grandit). Fonctionne.

**System prompt de chat (v2)** : elixness se présente en assistant de
conversation (« Je suis elixness, un assistant conversationnel de
programmation conçu en Elixir... ») — plus le traducteur de docstrings.
Répond en français par défaut, concis, peut utiliser le contexte de fichiers.

**Limites connues** : `--files` pas encore branché (le dropdown viendra avec
ratatui).

## Le tool spawn_agent — déléguer depuis le chat (2026-08-27)

Le chat expose un tool **`spawn_agent`** au modèle (le pattern des 3 harness :
le spawn EST un tool, pas une commande slash). Le modèle décide de déléguer
quand la tâche a des sous-tâches indépendantes.

- **Schema** : `{prompt, model?}` — le child a sa propre conversation fraîche
  (zéro historique parent), hérite du modèle parent.
- **Le prompt du chat guide le modèle** : « spawn one subagent per subtask ».
- **Usage agrégé** : `spawn_agent` retourne `{:result, contenu, usage_child}`,
  le loop additionne l'usage des childs au parent → la conso de TOUS les
  agents est visible (test : parent 2 671 → parent+2 childs 4 733 tokens).
- **Parallélisme** : les tool_calls multiples (surtout les spawn) s'exécutent
  en `Task.async_stream` parallèle (le maxParallelToolCalls de deepseek).

**Testé** : « Translate these 2 docstrings by spawning ONE subagent per
docstring » → le modèle a spawn 2 agents, un par docstring, et synthétisé les
résultats. Le nombre d'agents dans le prompt est un signal fiable.

## Le executionMode par tool (pattern deepseek)

Chaque tool déclare son mode d'exécution dans le registre :
- `read_file`, `search_files`, `spawn_agent` → `:parallel` (peut tourner
  en même temps que d'autres calls)
- `write_file` → `:exclusive` (barrière — attend que les calls en vol se
  vident, évite les courses sur les écritures)
- défaut → `:exclusive`

Le loop (`execute_calls/2`) groupe les tool_calls par mode : les `:parallel`
partent ensemble (`run_parallel`, borné à 10), les `:exclusive` forment une
barrière (max 1). Les résultats sont **réordonnés par id de call original**
(l'API OpenAI exige les tool results dans l'ordre des tool_calls).

**Test réel (3 fichiers, loop + executionMode)** :
```
✓ llm.ex        turns=3
✓ req_llm.ex    turns=3
✓ ner.ex        turns=4
total: 3/3, ~25s mural, ~$0.0005, parallélisme ~2.2x
```
Le read_file/spawn partent en parallèle, le write_file attend — pas de
course sur les écritures, ordre respecté (l'API accepte). Référence :
opencode = concurrency unbounded (tout en parallèle, pas de sécurité),
deepseek = executionMode par tool (le plus sûr), Hermes = concurrent quand
indépendants.

## Tests chat avec spawn — ÉCHEC de l'orchestration par le modèle

2 tests dans le chat (même consigne : traduire les commentaires FR de
`domain/`), pour comparer avec les batchs A-I :

**Test 1 — « Lance 10 agents »** : `prompt=46448, completion=2501`. Le modèle
explore (recense 20 fichiers, détecte partiellement le FR), **sature les 8
turns (MAX_STEPS) avant de spawner → 0 agent lancé, 0 traduction**.

**Test 2 — sans nombre** : `prompt=170928, completion=12709`. Le modèle fait
un travail ÉNORME : inventaire complet (21 fichiers), lecture intégrale,
identification précise des 8 fichiers avec FR + 13 déjà en anglais, analyse
fine (slugs à préserver, messages d'erreur = contenu fonctionnel, « récit »
terme technique conservé). **Mais sature encore → 0 agent spawné, 0
traduction** — il recommande de « lancer un subagent par fichier » sans le
faire.

| Test | prompt | completion | résultat |
|---|---|---|---|
| I (batch, 10 fichiers) | 413k | 7.5k | 10/10 traduits, 16.5s, ~$0.0015 |
| Chat test 1 (sans flatmap) | 46k | 2.5k | 0 spawné, 0 traduit |
| Chat test 2 (sans flatmap) | 171k | 12.7k | 0 spawné, 0 traduit |

**Conclusion** : le modèle ne peut PAS orchestrer (découverte + spawn) dans
8 turns — le batching de Hermes n'a pas suffi, la rigueur du prompt de chat
(verification, tool_persistence) le pousse à tout analyser avant de déléguer.
**C'est la preuve qu'il faut le flatmap mécanique** (roadmap) : le harness
découpe + spawn + collecte, pas le modèle. Le chat orchestre mal et coûte
cher pour rien.

## Les mêmes tests APRÈS le flatmap + traçage — SUCCÈS

Les 2 mêmes tests relancés avec le tool `flatmap` (le modèle délègue au
harness) + `Elixness.Trace` (observabilité) + les fixes Discover/UTF-8 :

| Test | trace | prompt | completion | résultat |
|---|---|---|---|---|
| Chat test 1 (« lance 10 agents ») | `flatmap: 1` | 110k | 25k | **10 fichiers traités, 0 erreur, 5 traduits** |
| Chat test 2 (sans nombre) | `flatmap: 1` + search:9 + write:1 | 287k | 56k | **7 traduits + vérification fine** (survey.ex corrigé) |

- **Test 1** : le modèle a appelé `flatmap` UNE fois → les 10 agents ont
  tourné en interne → 5 fichiers traduits (5 déjà EN).
- **Test 2** : `flatmap` + `search_files` de vérification + un `write_file`
  pour corriger le dernier résidu (survey.ex) → 7 traduits.
- **La comparaison** : avant = 0 agent, 0 traduit, saturation (46k/171k
  gaspillés). Après = flatmap → agents lancés, traductions écrites, tout
  visible dans la trace.
- **Les bugs trouvés par le traçage** : Discover (path `lib/...` → `lib/lib/**`
  → 0 fichier) et UTF-8 (octets binaires → Jason.EncodeError) — les deux
  corrigés. Sans la trace, « 0 agents » restait incompréhensible.

## opencode — testable avec l'API de Hermes (provider nous)

opencode (le 3e concurrent) peut être lancé avec l'API de Hermes (provider
`nous`, modèle `deepseek/deepseek-v4-flash`) — vérifié et testé :

**Config** (`opencode.jsonc`) — provider OpenAI-compatible :
```jsonc
{
  "provider": {
    "nous": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Nous",
      "options": {
        "baseURL": "https://inference-api.nousresearch.com/v1",
        "apiKey": "{token de ~/.hermes/auth.json}"
      },
      "models": {
        "deepseek-v4-flash": { "name": "DeepSeek V4 Flash" }
      }
    }
  }
}
```

**Commande** (via bun dans le monorepo ~/git/opencode) :
```
bun run opencode run 'message' --model nous/deepseek-v4-flash
```
Testé : `> build · deepseek/deepseek-v4-flash → OK`.

**Notes** : `bun install --ignore-scripts` (tree-sitter-powershell cassé) ;
opencode pas installé globalement — passer par l'entrée source du monorepo.
Le token est lu sans être affiché.

**La batterie de tests** : 3 concurrents — **elixness** (flatmap), **C**
(Hermes complet), **opencode** (via l'API Hermes). Comparer sur les 4 axes
(coût, temps, qualité, traçage) avec le même prompt et les mêmes fichiers.

## read_file borné (pattern deepseek)

Le `read_file` est **borné** pour forcer le modèle à chercher avant de lire
(le pattern des 3 harness — deepseek caps dures, opencode liste de dossiers) :

- `read_file(path, offset?, limit?)` — lignes numérotées, défaut 2000 lignes max
- Footer de pagination : `(Showing lines X-Y of Z. Use offset=Y+1 to continue.)`
- Sur un **dossier** : liste les entrées `(directory)` (le modèle voit la
  structure sans lire)
- Description : « do NOT read whole files at once »

**Mesuré** : « quels sont les tools d'opencode ? » → 176 673 prompt (read
entiers) → **66 540** (read borné, 2.7x moins), qualité égale ou meilleure.

## Les 3 tests du benchmark vs C (Hermes)

Le goal : elixness doit faire **mieux que Hermes** sur 3 scénarios concrets.
Chaque évolution est comparée à C sur les 4 axes (coût, temps, qualité, traçage).

### Test 1 — Traduction (commentaires FR → EN, `lib/inductive/domain`)

| Version (commit) | prompt | flatmap | résultat |
|---|---|---|---|
| avant compact | 807k | 1 | 5 fichiers |
| streaming (6d4de16) | 428k | 1 | 7 fichiers |
| read borné (09bf92e) | 1.4M | 2 (re-lancé) | 8 fichiers ❌ |
| sans plafond (7b3ddaf) | 463k | 1 seul | 10 fichiers, 4 traduits |
| **nettoyé (ec2e47b)** | **390k** | **1 seul** | **10 fichiers, agent_task.ex traduit, git diff OK** ✅ |
| streaming fix (0cf508f) | 431k | 1 seul | 10 fichiers, 2 modifiés (agent_task.ex + datation.ex), 8 déjà EN, git diff + mix compile OK ✅ |
| flatmap illimité (070704f) | **146k** | 1 seul (limit 10 passé par le modèle) | 10 fichiers, 1 modifié (agent_task.ex), 9 déjà EN, cost **0.0014 $**, 41.5s, git diff + compile OK ✅ |

**Comparaison à C (Hermes, 10 fichiers)** : C = 42s, ~0.0168 $, 10/10, structure préservée.
Le run le plus propre (flatmap illimité) : **0.0014 $ pour 10 fichiers (~12x moins cher que C)**,
41.5s ≈ C (42s). Le modèle a déduit `limit: 10` du langage naturel (« les 10 premiers
fichiers ») sans qu'on le passe explicitement — comportement attendu du flatmap illimité.

Le retrait du plafond de 10 agents (commit 7b3ddaf) a éliminé le re-flatmap :
`flatmap: 1` (traite tous les fichiers FR), vérification par `git diff` +
`mix compile` (le pattern opencode/Hermes). Prompt 1.4M → 463k.
**Le nettoyage (ec2e47b)** : retrait du code spécifique traduction (batch
translate, extraction moduledoc AST, filtre FR) → Discover générique (liste
les fichiers). **390k prompt (meilleur score), comportement propre** (flatmap
→ git → réponse, 0 read_file/search inutiles). Le code custom des moduledoc
faisait partie du problème.
Reste : le mode `:direct` réparé (écrire dans le source) pour vraiment
battre C sur le coût (C ≈ 0.0168 $, ~42s).
**Le fix streaming (0cf508f)** : la CaseClauseError de `LLM.chat` (contrat
Req `into:` violé) a fait échouer tous les runs — corrigé en portant l'état
SSE dans `response.private[:sse]`. Re-testé : 431k prompt, flatmap 1, 10
agents, 0 erreur, 2 fichiers modifiés (agent_task.ex + datation.ex, les 8
autres déjà EN), vérifié par git diff + mix compile.
**Le fix UTF-8 (chat)** : le streamer affichait les args/résultats de tools
sans sanitize → des octets UTF-8 invalides (pattern `search_files` accentué
généré par le modèle) faisaient crasher `:io.put_chars` (ArgumentError).
Corrigé en sanitisant (U+FFFD) avant écriture. Re-testé : run complet sans
crash, **cost réel affiché (0.00665 $)**. Le modèle a relancé flatmap avec
`limit: 30` pour couvrir les 29 fichiers (le défaut du tool est 10) →
29/29 OK, 9 fichiers modifiés, 0 commentaire FR restant (grep accentué),
compile OK. Cost 0.00665 $ pour 29 fichiers vs C ≈ 0.0168 $ pour 10.
**Comparé aux 2 autres harness (protection UTF-8)** : deepseek-harness est
web-first (pas d'`IO.puts`) — protection à l'entrée : `TextDecoderStream()`
non-fatal (sse.ts:32) → U+FFFD, `TextRetainer` (bornes UTF-8 sûres),
`parseArguments` défensif, lecture `fatal:true` + erreur `FS_NOT_TEXT`
(fsio.ts:331). Hermes (Python) : **triple filet** — `try/except` autour de
chaque écriture terminal (`_cprint` cli.py:3672, « display must never abort
a turn »), previews tronquées/redactées des args (jamais le raw stream),
`_sanitize_surrogates` → U+FFFD à la persistance. **La leçon** : ce n'est
pas la sanitisation seule qui sauve — c'est le `rescue` autour de l'écriture
(ne jamais tuer le process pour un problème d'affichage) + ne pas refléter
le raw. Elixness a adopté les deux (sanitize U+FFFD + rescue dans
`stream_tools`).

### Test 2 — Recherche sur internet (web_search + résumé 3 sources)

Sujet : « DeepSeek V4 Flash : performances et usages » — chercher 3+ sources
et résumer. Réalisé le 2026-08-27 (DuckDuckGo, pas encore Exa).

| | Hermes (subagent) | elixness (chat) |
|---|---|---|
| api_calls / tool_calls | 3 | **5** (2 web_search + 3 web_extract) |
| prompt (input) | 24.4k + cache 42.5k | **14.7k** + cache 6.7k ✅ |
| completion | 1.5k | 2.1k |
| coût | ~0.0022 $ | **0.00015 $** (~15x moins cher) ✅ |
| temps | 44.6s | **~6s exec** ✅ |
| sources | 4 (DeepInfra, Lightning AI, Morph, LLM-Stats) | 3 (DataCamp, ZenMux, AI Stupid Level) |
| qualité | équivalente | équivalente |

Note : métriques Hermes depuis `session_model_usage` (session
`20260827_193830_76360d`, le subagent web) : 3 api_calls, input 24.4k + 42.5k
cache, output 1.5k, ~0.0022 $. elixness : prompt 14.7k + 6.7k cache, output
2.1k, 0.00015 $, 5 tool_calls (~6s exec). Les 2 ont produit un résumé
structuré de qualité équivalente (présentation, benchmarks SWE-bench 79% /
GPQA 88%, prix, usages, points forts/faibles) avec 3-4 sources citées.
elixness est ~15x moins cher et plus rapide — le web_search/web_extract
(DuckDuckGo) suffit pour ce cas, Exa (MCP) à brancher pour aller plus loin
(priorité 3 roadmap).

### Test 3 — Explorer un repo (ex. « quels sont les tools d'opencode ? »)

| | Hermes | elixness explore_repo (2c25719) |
|---|---|---|
| prompt | 24 512 | **20 969** ✅ |
| coût | 0.0054 $ | **0.001 $** (5.4x) ✅ |
| temps | ~105s | **23.6s** (4.5x) ✅ |

elixness **bat Hermes** sur l'exploration de repo (explore_repo : rg → flatmap
→ reduce). À re-confirmer avec le read borné (09bf92e).

### Test 3b — « Comment les skills de Hermes sont configurés ? » (même repo)

Même question posée aux 2 moteurs dans `~/git/hermes-agent` : un chat elixness
(explore_repo + lecture ciblée) vs un agent Hermes (subagent). Les 2 ont
produit une réponse structurellement équivalente (format SKILL.md + frontmatter,
sources de stockage, config.yaml `skills:`, ESSENTIAL_SKILLS, index prompt).

| | Hermes (subagent) | elixness (chat) |
|---|---|---|
| api_calls / tool_calls | 26 | **11** ✅ |
| prompt (input) | 60.5k + cache_read 1149k | 528k + cache_read **300k** |
| completion | 10.4k | 69k |
| coût | ~0.019 $ | **0.0055 $** (~3.5x moins cher) ✅ |
| temps | 196s | **~90s** ✅ |
| fichiers explorés | — | 200 (garde-fou) |
| limite de pas atteinte | oui | oui |
| qualité | équivalente | équivalente |

Note : les métriques Hermes viennent de la table `session_model_usage`
(état.db, session `20260827_182942_298310`, le subagent skills) : 26 api_calls,
input 60.5k + **1149k cache-read**, output 10.4k, ~0.019 $. Les métriques
elixness viennent du run le plus récent (mesure du cache-read ajoutée, commit
cache-read) : explore_repo retourne `{:result, texte, usage}` (fix ddd2736 →
le loop agrège le coût des agents internes), et `normalize_usage` mesure le
`cached_tokens`/`prompt_cache_hit_tokens` (pattern des 3 harness) :
**528k prompt + 300k cache-read + 69k completion + 0.0055 $**.
Runs précédents (même question) : sans garde-fou, explore_repo borné à 10
fichiers → 17 tool_calls, cost 0.00045 $ (non agrégé, faux), ~90s. Avec
garde-fou 200 + fix usage → 10 tool_calls, 0.0048 $, ~159s.
**Le cache-read d'elixness (300k) est mesuré pour la première fois** : le
provider DeepSeek fait du prefix-caching AUTOMATIQUE (aucun marqueur à
envoyer — confirmé par l'analyse des 3 harness). Les 300k tokens relus en
cache ne sont pas facturés au prix plein : c'est une partie de l'explication
du coût bas. Malgré un volume de tokens plus élevé, elixness reste ~3.5x
moins cher que Hermes en $ — le token n'est pas le bon comparateur, le $ oui.

**Leçon des 3 harness (deepseek/opencode/Hermes, analysés 2026-08-27)** : aucun
ne pré-filtre les fichiers par pertinence, aucun n'a de map-reduce hiérarchique
ni de scoring sémantique. La pertinence est décidée par le MODÈLE (via
search_files/glob/read) ; le runtime ne fait que BORNER : caps par tool
(grep/glob ≤100-250, read ≤2k lignes/50KB), concurrency (opencode unbounded,
Hermes max_concurrent_children 10, deepseek maxConcurrentAgents/1000),
profondeur de délégation (défaut 1), compaction/truncation du contexte.
→ elixness a adopté la même philosophie (commits eb5127a, ab78e23) :
`explore_repo`/`flatmap` sont illimités (tous les fichiers) mais gardent un
garde-fou budget (`@max_analyze 200` : au-delà, on coupe — le modèle réduit le
périmètre d'abord) + concurrency bornée (20, évite la saturation du pool Finch
sur les gros repos).

### Test 3c — Re-validation « Comment les skills de deepseek-harness sont gérés ? » (2026-08-31)

Re-validation du Test 3b sur `~/git/deepseek-harness` (~7900 fichiers), la
MÊME question posée aux 2 moteurs en parallèle (chat elixness vs subagent
Hermes). Le but : vérifier la peur « elixness émet BCP plus de tokens que
Hermes en explorant ».

| | Hermes (subagent) | elixness (chat) |
|---|---|---|
| api_calls / tool_calls | 9 / 19 | — / 9 (explore_repo:1, glob:3, read:4, search:1) |
| prompt (input neuf) | 67.7k + cache_read 276k | 577.6k + cache_read 207k |
| completion | 5.7k | 88.1k |
| **tokens neufs totaux** | **~73k** | **~666k (9x plus) ❌** |
| coût | 0.0095 $ | **0.0092 $** ✅ (égal, même léger avantage) |
| temps | ~69s | ~130s |
| fichiers analysés | composition ciblée | 200 (garde-fou) |
| qualité | riche, structurée | riche, structurée |

**Verdict honnête** : la peur du user est FONDÉE et mesurée — elixness émet
**~9x plus de tokens neufs** que Hermes sur la même question (666k vs 73k).
MAIS le coût en $ est quasi identique (0.0092 $ vs 0.0095 $) : le token
DeepSeek est ~10x moins cher + le cache-read (207k) amortit. Le temps passe à
Hermes cette fois (~69s vs ~130s, l'explore_repo 200 agents plombe le mural).
**Le point faible confirmé = le VOLUME de tokens d'explore_repo** (1 agent
LLM/fichier avec contenu complet), pas le $. C'est le chantier de la roadmap
section 5 (P1 : catalogue en 2 passes). Métriques Hermes : state.db session
`20260831_125039_8fce0c` (enfant de cette session).

### Test 3d — tool `catalog` (catalogue ZERO-LLM, commit 9173b03, 2026-08-31)

Réponse au point faible du 3c : un tool `catalog(path)` qui extrait par regex
(module/def Elixir, export/class/function TS, def/class Python, titres md +
moduledoc de tête) → ~50-100 tokens/fichier au lieu des 4000 chars de
contenu d'explore_repo. Zéro LLM, ~2s pour 1000 fichiers.

- **Catalogue seul** (deepseek-harness entier) : 1000 fichiers → **~62k tokens
  est.** (vs 577k pour explorer les mêmes par explore_repo) — la couverture
  inclut bien `packages/skill/*` (24 fichiers).
- **Re-test chat avec catalog** (même question) : TRACE `catalog: 1,
  explore_repo: 1, read_file: 7` → prompt **668k, cost 0.009 $**.
  ❌ **PAS DE GAIN** : le modèle a appelé catalog PUIS explore_repo quand même
  (le system prompt le pousse encore vers le « deep analysis » de tout le
  dossier). Le catalogue est prêt (mécanique, zéro-LLM, ~62k) mais le modèle
  doit apprendre à s'en servir SANS retomber sur explore_repo — levier =
  guidance du prompt (catalog → read ciblés, explore_repo réservé au deep
  analysis explicite).

## Notes

- Le token est lu brut depuis auth.json : s'il est expiré, l'API répond 401 et
  elixness le signale (relancer `hermes` pour rafraîchir).
- Limite connue : le modèle `deepseek-v4-flash` aplatit les traductions sur une
  seule ligne en appel nu (elixness). Via le coding agent Hermes, la structure
  est préservée.
- `TimeZoneInfo: Update failed! {:error, :enotdir}` au boot : cosmétique
  (dép Jido qui cherche son cache tz dans l'escript), sans effet.
- Pool 1 agent : le timeout de checkout doit couvrir la durée du run complet
  (`length(jobs) × 130s`), sinon les jobs qui attendent le worker sont
  rejoués (doublons).
- Timeout d'action : le défaut de `jido_action` est 30s, trop court pour un
  appel LLM → `config :jido_action, default_timeout: 120_000`.
