# Roadmap elixness

État au 2026-08-27. Le moteur existe (Loop, Tools, Inbox, ChildRegistry,
Context, chat). Les prochaines étapes, par ordre de valeur.

## 1. Le loop mécanique — un tool `flatmap`

**Problème observé** : le chat avec spawn échoue. Le modèle explore (search →
read) et sature les 8 turns de MAX_STEPS avant de spawner. Les 2 tests :
- « lance 10 agents » → **0 agent spawné** (saturé en exploration, 20 fichiers
  recensés mais pas de spawn)
- sans nombre → idem attendu

**Le fix** : un tool `flatmap` que le modèle appelle UNE fois au lieu
d'orchestrer lui-même. Le harness découpe + spawn + collecte :

```
Le modèle appelle :  flatmap("traduis les commentaires FR→EN", dossier)
Le harness :         Discover (liste les fichiers) → spawn 1 agent/fichier
                     → collecte → retourne le total au modèle
```

C'est le **flatmap de Huntley rendu mécanique** : le modèle ne compte pas, ne
spawn pas un par un — il délègue au harness qui orchestre. Pattern des 3
harness : le modèle demande, le harness orchestre.

- `Elixness.Flatmap` : Discover → pool (Task.async_stream) → Reduce
- Le tool `flatmap` dans Tools (schema + executor avec état)
- Le résultat retourne le total (traductions + usage agrégé)

## 2. Les logs des tools traçables — affichage EN DIRECT (streaming)

**Problème observé** : aujourd'hui les tool_calls s'exécutent mais on ne voit
**rien en cours de route** — le chat n'affiche que la réponse finale (et le
trace seulement APRÈS). On veut la **traçabilité** (le flamegraph de
context-engineering appliqué aux tools) et surtout **l'affichage en direct** :
comme opencode/Hermes, on voit chaque tool call apparaître au fur et à mesure.

**Le but** : voir à tout moment ce que fait un agent, EN TEMPS RÉEL :
- quels tools il appelle, avec quels arguments (affiché dès le lancement)
- les résultats (succès/erreur, taille) (affiché dès la fin du tool)
- le temps, les tokens par tool
- l'état des enfants (ChildRegistry : combien d'actifs, leurs pids)
- un `spinner`/indicateur pendant l'exécution (le modèle « travaille »)

**Implémentation envisagée** :
- Chaque `execute` de tool → journalise + **émet un événement** (broadcast)
- Un `Elixness.Trace` (Agent/ETS) : la trace des derniers événements
- **Le chat AFFICHE les événements en direct** (le loop pousse les events au
  CLI qui les imprime, sans attendre la réponse finale)
- Commande `/trace` pour l'historique
- Logs des enfants dans ChildRegistry

**Pourquoi c'est important** : le test benchmark elixness vs Hermes a montré
que l'agent elixness explore sans rien afficher en direct (le log reste à 12
lignes pendant qu'il travaille) — impossible de savoir ce qu'il fait. L'affichage
en direct est LA différence UX avec opencode/Hermes qui streament les tool calls.

## 3. Le test de recherche internet — web_search + résumé 3 sources

**Problème à valider** : elixness n'a pas de tool de recherche web. On veut
tester le cas « résume ce sujet en cherchant 3 sources sur internet » — un
2e benchmark vs C (Hermes fait déjà web_search + résumé).

**Le but** :
- Ajouter un tool `web_search` (+ `web_extract` ou lecture d'URL) — ✅ FAIT
  (DuckDuckGo HTML, testé)
- **Passer web_search sur Exa MCP** (comme opencode) — gratuit 150 appels/jour
  sans clé, ou $10/mois de crédits avec clé (~2800 recherches). Optimisé LLM
  (context, livecrawl). Rendre elixness comparable à opencode/Hermes dans le
  benchmark. DuckDuckGo reste un fallback.
- Tester : « résume le sujet X en cherchant 3 sources »
- Comparer elixness vs C sur les 4 axes (coût, temps, qualité, traçage)

**Design envisagé** :
- Simple d'abord : `web_search` + `web_extract` (le modèle cherche, lit, résume) — ✅ tools faits
- Si le chat explore trop (comme avant) → `flatmap_web` mécanique (le harness
  cherche, spawn 1 agent/source, synthétise)
- Le reduce (synthèse multi-sources) est un nouveau pattern à tester

**Pourquoi c'est important** : valide le flatmap sur un cas NON trivial
(synthèse > traduction) et ajoute un vrai tool utile — elixness devient un
agent complet. Test validé par l'utilisateur (2026-08-27) avant la bifurcation
exploration de repo.

**Exa (décision, 2026-08-27)** : MCP public `https://mcp.exa.ai/mcp` — gratuit
sans clé (150 calls/jour, 3 QPS), ou clé API (20$ signup + 10$/mois, Search $7/1000
req). Même provider qu'opencode → comparaison honnête. À brancher pour le test
de recherche internet (DuckDuckGo = fallback).

## 4. Le tool `explore_repo` — l'exploration mécanique (différenciant)

**Problème observé** : le benchmark elixness vs Hermes (explorer deepseek-harness)
a montré qu'elixness explore trop (17 tools, 174k prompt, 8 turns saturés avant
fin) alors que Hermes finit en 92s/31k prompt. Le modèle explore manuellement
(relit tout) → cher + saturation.

**La solution** : un tool `explore_repo` mécanique — le harness scanne + lit +
résume le repo SANS que le modèle explore (comme le flatmap pour la traduction).

**Pourquoi c'est un différenciant** : AUCUN des 3 harness (deepseek, opencode,
Hermes) n'a de tool d'exploration dédié — ils explorent tous par composition
(glob + grep + read). Un `explore_repo` qui résume la structure d'un repo en 1
appel serait un avantage unique pour elixness.

**Design envisagé** :
- `explore_repo(path)` → le harness fait glob (structure) + extrait les points
  clés (moduledoc, définitions, TODO) → résumé structuré → retourne au modèle
- Le modèle n'a plus besoin de lire fichier par fichier
- Basé sur ripgrep (le backbone recommandé) si dispo, sinon glob + read

**Benchmark attendu** : rejouer « explorer deepseek-harness » → elixness avec
explore_repo devrait passer de 174k prompt/8 turns à ~30k prompt/2-3 turns →
compétitif avec Hermes (31k).

## 5. Réduire les tokens d'explore_repo (le trade-off du « 1 agent/fichier »)

**Problème observé (benchmark Test 3b, 2026-08-27)** : le benchmark « comment
les skills de Hermes sont configurés ? » a révélé un vrai trade-off. Avec le
garde-fou 200 (ab78e23), explore_repo analyse 200 fichiers **avec le contenu
complet** → elixness émet **528k prompt neuf + 300k cache-read + 69k output**
(~897k tokens) alors que Hermes explore par composition (search_files + read
ciblés) → **60.5k prompt + 1149k cache + 10.4k output**. Hermes est ~9x plus
efficace en prompt neuf et ~7x en output.

**Pourquoi ça coûte quand même moins cher** : elixness reste ~3.5x moins cher
en $ (0.0055 $ vs 0.019 $) grâce au prix du token DeepSeek + 300k en
cache-read. Mais en **volume de tokens**, le « 1 agent par fichier avec le
contenu complet » est gourmand — c'est le point faible si les rate limits /
quotas deviennent un souci.

**Leçon des 3 harness (analysés 2026-08-27)** : aucun ne pré-filtre les
fichiers, mais Hermes/opencode explorent par **composition ciblée**
(search_files/grep + read borné) au lieu de tout passer en bloc. Le modèle
décide quoi lire, le runtime borne (caps ≤100-250, read ≤2k lignes).

**Design envisagé pour réduire les tokens** :
- explore_repo ne passe plus le contenu COMPLET aux agents : seulement le
  moduledoc / les headers / les définitions (extraction mécanique, zéro LLM),
  comme le prévoyait le design initial de la section 4 (« extrait les points
  clés : moduledoc, définitions, TODO »).
- Ou : découpage en 2 passes — 1re passe `search_files` ciblé (le modèle
  réduit le périmètre), 2e passe explore_repo sur le sous-ensemble pertinent.
- Mesurer l'effet : rejouer le Test 3b, viser ~100k prompt max au lieu de 528k.

## Après (backlog)

- Le dropdown fichiers (ratatui) — les fichiers en contexte visibles
- L'annulation des enfants (`ChildRegistry.cancel` — Process.exit :shutdown)
- La persistance des sessions (resume)
- Le system prompt de chat complet (skills, règles projet)

## Notes

- Le flatmap mécanique est la priorité : il transforme le chat d'« orchestration
  par le modèle » (lent, sature) en « flatmap par le harness » (rapide, fiable).
- La traçabilité vient juste après : sans logs, impossible de debuguer les
  agents enfants.
- Trade-off tokens vs $ (Test 3b) : explore_repo gagne en $ et en temps mais
  consomme ~9x plus de prompt neuf que Hermes (528k vs 60.5k) — le « 1 agent
  par fichier avec contenu complet » est gourmand. Voir section 5.
