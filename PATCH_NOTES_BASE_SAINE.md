# EAP - Base saine, indépendante du CAP

Base de départ : `master` officiel d'EAP (`williamdefly/Evolutionaddonpack`), au
commit `3e7e23a` ("Fixed Ideas link"). **Aucune** de tes modifications
précédentes n'a été reprise : tout repart de ce master propre.

Le patch complet est dans `eap_clean_base.patch`. Comment l'utiliser : voir la
toute dernière section de ce document.

Résumé : 25 fichiers touchés, 1 fichier supprimé, **zéro** référence restante
à `"stargate_*"` en comparaison de classe, **zéro** dépendance non protégée
aux tables globales `StarGate.*` / `SGLanguage.*` du CAP, et **aucune
fonctionnalité perdue** : la seule qui s'appuyait sur une fonction du CAP sans
équivalent EAP (le bonus de surcharge quand l'iris est fermé) a été recréée
nativement plutôt que simplement supprimée - détails au point 4.

---

## 1. Suppression totale de l'ancien système de swap

- **Supprimé** : `lua/eap_librairies/server/cap_reversecompatibility.lua`
  (tout le fichier - c'était l'ancien hook `PlayerSpawnedSENT` qui remplaçait
  les entités CAP par leurs équivalents EAP).
- **`lua/autorun/eap_include.lua`** : retiré le `include(...)` correspondant.
  Pas de remplacement pour l'instant - la couche de compatibilité reviendra
  dans une étape séparée, une fois cette base testée.

Plus aucun script Lua d'EAP ne crée de swap sur une entité d'un autre addon.

---

## 2. Vrais bugs de base corrigés (indépendants du CAP)

### a) `stargateGetRingAngle()` (4 fichiers)

Cette fonction compare la classe de **l'entité EAP elle-même** à une liste de
classes... du CAP :

```lua
local vg = {"stargate_movie","stargate_sg1","stargate_infinity","stargate_universe"};
local class = this:GetClass();  -- pour une gate EAP, class vaut "sg_sg1", "sg_universe", etc.
if (not table.HasValue(vg,class)) then return -1 end  -- toujours vrai -> toujours -1
```

C'était déjà le cas dans le `master` d'origine, **avant** toute modification
de compatibilité. C'est très probablement le vrai responsable du problème que
tu avais remarqué au tout début (`stargateGetRingAngle` qui renvoie toujours
`-1`), indépendamment du CAP. Corrigé dans les 4 moteurs de script d'EAP
(E2, ExpAdv2, Wire Gates, Starfall) : liste et comparaison passées en
`"sg_movie","sg_sg1","sg_infinity","sg_universe"` / `"sg_universe"`.

### b) Sélecteur d'adresse Orlin - `lua/eap_librairies/vgui/stargatemenus.lua`

Le menu testait `self.Entity:GetClass()=="stargate_orlin"` pour savoir si LA
PORTE AFFICHÉE est une Orlin - toujours faux pour une gate EAP (classe
`sg_orlin`). Fonctionnalité silencieusement cassée, pas un crash. Corrigé en
`=="sg_orlin"`.

### c) Propriété clic-droit "AtlType Off" - `lua/entities/sg_atlantis/shared.lua`

Nouvellement trouvé en repassant sur l'ensemble du dépôt : une des entrées du
menu clic-droit (propriété `Lib.Atl.AtlType.Off`, celle qui désactive le
dial rapide) testait `ent:GetClass()!="stargate_atlantis"` alors que les 6
autres entrées du même fichier testent toutes `!="sg_atlantis"`. Résultat :
cette entrée de menu était invisible/désactivée en permanence sur une gate
Atlantis d'EAP. Corrigé pour matcher les autres (`!="sg_atlantis"`).

---

## 3. Crashs garantis sans le CAP, corrigés avec les équivalents natifs d'EAP

### a) Type/couleur d'Event Horizon - `lua/entities/sg_base/init.lua`

`StarGate.EventHorizonTypes` → `Lib.EventHorizonTypes` (table native d'EAP,
déjà utilisée ailleurs dans `eventhorizon/init.lua` et `sg_base/shared.lua`).

### b) Texte d'aide de l'outil - `lua/eap_librairies/vgui/init.lua`

`SGLanguage.GetMessage("stool_help")` → `Lib.Language.GetMessage("stool_help")`.

---

## 4. `stargateOverloadTime()` : le bonus "iris fermé = surcharge x2" est recréé nativement

C'est le point que tu as soulevé : plutôt que de supprimer ce bonus (ce que
je proposais initialement, faute d'équivalent EAP), j'ai ajouté une vraie
fonction native à EAP pour le préserver.

En creusant dans `sg_base/modules/lib.lua`, j'ai trouvé que chaque stargate
dispose déjà de `self:GetIris()` (cherche l'entité iris la plus proche
posée sur elle - utilisée par le menu VGUI et par e2 pour `IrisToggle()`),
et que les deux entités iris d'EAP (`sg_iris`, `goauldiris`) exposent toutes
les deux un champ `self.IsActivated` (vrai quand l'iris est fermé). Tout ce
qui manquait, c'est la fonction qui combine les deux - je l'ai ajoutée juste
à côté de `GetIris()` :

```lua
-- Native EAP replacement for CAP's StarGate.IsIrisClosed(gate)
function ENT:IsIrisClosed()
	local iris = self:GetIris();
	return IsValid(iris) and iris.IsActivated or false;
end
```

Et j'ai remis le bonus x2 dans les 4 moteurs de script, maintenant branché
sur cette fonction native (`this:IsIrisClosed()` / `Entity:IsIrisClosed()` /
`Ent:IsIrisClosed()` selon le fichier) au lieu de `StarGate.IsIrisClosed(...)` :
- `lua/entities/gmod_wire_expression2/core/custom/stargate.lua` (E2, 2 occurrences)
- `lua/expadv/components/custom/stargate.lua` (ExpAdv2, 2 occurrences)
- `lua/wire/gates/stargate.lua` (Wire Gates, 1 occurrence)
- `lua/starfall/libs_sv/stargate.lua` (Starfall, 2 occurrences)

Résultat : comportement identique à avant (y compris avec le CAP installé,
puisque `GetIris()` trouve n'importe quelle entité avec `IsIris=true`, CAP ou
EAP), mais sans aucune dépendance à une table globale du CAP.

---

## 5. `stargateRandomAddress()` : branché sur la fonction native d'EAP

Dans Starfall (2 occurrences), l'appel à `StarGate.RandomGateName(...)`
n'était pas protégé -> crash sans le CAP. Dans E2 et ExpAdv2 (2+2
occurrences), l'appel était protégé par `StarGate and StarGate.RandomGateName`,
donc pas de crash, mais **la fonction ne faisait rien du tout** sans le CAP,
même sur une gate purement EAP.

Dans les 3 moteurs, remplacé par l'équivalent natif d'EAP,
`Lib.RandomGatesName(ply,ent,count,wire,mode)` (même signature exacte, déjà
utilisée ailleurs dans `eap_librairies/server/general.lua`). Cette fonction
marche maintenant aussi sur les gates EAP sans le CAP installé, ce qui
n'était pas le cas avant.

---

## 6. Nettoyage de toutes les traces textuelles restantes

Plus aucune occurrence de `StarGate.` ou `SGLanguage.` dans le code actif, et
plus aucun littéral `"stargate_"` utilisé comme nom de classe CAP (les seuls
`"stargate_..."` qui restent sont des noms de convars/clés 100% internes à
EAP, comme `stargate_group_system` ou `stargate_eap_dhd_ring` - ce sont des
réglages d'EAP, pas des références au CAP) :

- **`lua/entities/stationary_staff_part.lua`** et **`energypulse_stun.lua`** :
  les blocs `if (SGLanguage!=nil and SGLanguage.GetMessage!=nil) then ... end`
  utilisaient `SGLanguage.GetMessage(...)` à l'intérieur - remplacés par
  `Lib.Language.GetMessage(...)` (sans condition, comme le font déjà tous les
  autres fichiers `energy_pulse_*.lua` du dépôt pour la même clé).
- **`lua/eap_librairies/shared/keyboard.lua`** : la garde
  `if((StarGate==nil or StarGate.KeyBoard==nil) and Lib.IsCapDetected==true) then return false; end`
  ne servait qu'à céder la main au CAP - supprimée, le commentaire au-dessus
  mis à jour (il ne mentionne plus le CAP).
- **`lua/eap_librairies/vgui/stargatemenus.lua`** : le nom de cookie VGUI
  `"StarGate.SAddressSelect"` renommé en `"EAP.SAddressSelect"` (effet de
  bord mineur et sans gravité : les joueurs perdront une fois leur
  position/taille de fenêtre mémorisée pour ce menu, qui sera simplement
  recréée au prochain réglage).
- **`lua/entities/tamperedzpm.lua`**, **`zpmmk3.lua`**,
  **`naquadah_generator_mk2.lua`** : un commentaire mort identique
  (`--if (self.HasRD) then StarGate.WireRD.OnRemove(self,true) end;`) retiré
  dans les 3 fichiers.
- **6 fichiers `energy_pulse_*.lua`** (`energypulse.lua`,
  `energy_pulse_destiny.lua`, `_mothership.lua`, `_alkesh.lua`, `_oneil.lua`,
  `_traveler.lua`, `_wraith.lua`) : des commentaires morts
  `--StarGate.CFG:Get(...)` retirés (c'étaient déjà des commentaires, aucun
  effet sur le comportement, juste du texte en moins qui mentionne le CAP).
- **`lua/expadv/components/custom/stargate.lua`** : un bloc entier de code
  mort (commenté `--[[ ]]--`, jamais exécuté, contenant même une faute de
  frappe `StagGate`) retiré - c'était une ancienne version non activée de
  `stargateRandomAddress`.

Le seul endroit où le mot `StarGate` apparaît encore dans tout le dépôt est
mon propre commentaire au-dessus de `IsIrisClosed()`, qui explique pourquoi
cette fonction existe (remplacement natif de `StarGate.IsIrisClosed`) - texte
indicatif, aucun effet en jeu.

---

## 7. Comment appliquer le patch

Le fichier `eap_clean_base.patch` est un patch Git classique (format
`git diff`), généré à partir du commit `3e7e23a` du `master` officiel
d'EAP - **pas** depuis ton fork. Deux façons de l'utiliser, selon où tu pars :

### Cas A - Tu repars d'un clone propre du `master` officiel (recommandé)

```bash
# 1. Clone propre du master officiel (si tu ne l'as pas déjà)
git clone https://github.com/williamdefly/Evolutionaddonpack.git
cd Evolutionaddonpack

# 2. Vérifie que tu es bien sur le bon commit (sinon le patch peut ne pas
#    s'appliquer si le master officiel a avancé depuis)
git log --oneline -1
# doit afficher : 3e7e23a Fixed Ideas link
# (si ce n'est pas le cas, voir "Si le patch ne s'applique pas" plus bas)

# 3. Copie eap_clean_base.patch à la racine de ce dossier, puis :
git apply --stat eap_clean_base.patch   # aperçu : liste des fichiers touchés
git apply --check eap_clean_base.patch  # vérifie que ça s'applique sans rien modifier
git apply eap_clean_base.patch          # applique réellement les changements
```

Si tu préfères un commit direct plutôt qu'un diff flottant dans ton dossier
de travail :

```bash
git am eap_clean_base.patch
```

(`git am` crée un commit avec le patch, `git apply` modifie juste les
fichiers sans committer - à toi de choisir selon ton habitude.)

### Cas B - Tu veux créer/mettre à jour ta branche perso (ex: `event_horizon_modif_v1.0` ou une nouvelle branche "base saine")

```bash
cd ton-fork-Evolutionaddonpack
git fetch origin
git checkout -b eap-base-saine 3e7e23a   # nouvelle branche basée EXACTEMENT sur le commit de départ
git apply eap_clean_base.patch
git add -A
git commit -m "Base EAP indépendante du CAP (suppression swaps, correctifs natifs)"
```

Tu as alors une branche propre, basée sur le `master` officiel + uniquement
ces correctifs, que tu peux pousser sur ton fork et utiliser pour les tests
en jeu.

### Si le patch ne s'applique pas ("patch does not apply" / "corrupt patch")

Ça arrive si tes fichiers locaux ne sont pas exactement identiques au commit
`3e7e23a` (par exemple si le `master` officiel a reçu de nouveaux commits
depuis, ou si tu pars d'un dossier déjà modifié). Dans ce cas, le plus sûr :

1. Clone un `master` propre à l'identique du commit `3e7e23a` (Cas A,
   étape 1-2) dans un dossier à part.
2. Applique le patch là, en vérifiant qu'il n'y a aucune erreur.
3. Compare ensuite ce dossier patché avec ton propre fork (avec un outil de
   diff, ou en copiant simplement les ~20 fichiers listés dans `git diff
   --stat` un par un) pour reporter les mêmes changements à la main dans ton
   propre fork.

Dis-moi si tu veux que je te fournisse directement les fichiers complets
déjà modifiés (plutôt qu'un patch) si l'application du patch pose problème -
c'est un peu plus volumineux à livrer mais ça évite tout souci d'application.
