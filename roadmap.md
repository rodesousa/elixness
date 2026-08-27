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
