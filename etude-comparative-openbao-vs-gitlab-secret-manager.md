# Étude comparative : OpenBao vs GitLab Secret Manager

**Date :** 11 mai 2026
**Auteur :** Préparé pour Massi
**Objet :** Aide à la décision pour le choix d'une solution de gestion de secrets, dans un contexte d'entreprise privée ou publique. Comparaison entre **OpenBao** (projet Linux Foundation) et **GitLab Secret Manager** (en version GitLab Premium / Ultimate).

---

## 1. Résumé exécutif

OpenBao et GitLab Secret Manager ne sont **pas réellement deux produits concurrents** au sens classique du terme. Depuis 2025, GitLab a officialisé une décision architecturale majeure (ADR 007) : son service natif « GitLab Secrets Manager » est **construit sur OpenBao**. Concrètement, GitLab héberge et exploite une instance OpenBao multi-tenant intégrée à sa plateforme DevSecOps.

La vraie question pour votre organisation n'est donc pas « OpenBao OU GitLab Secret Manager », mais plutôt :

- **Option A — OpenBao auto-hébergé** : vous déployez et opérez vous-même OpenBao, et vous l'intégrez à GitLab via l'intégration Vault existante (disponible en Premium).
- **Option B — GitLab Secrets Manager** : vous laissez GitLab opérer OpenBao pour vous, à l'intérieur de votre instance GitLab (Ultimate uniquement, en beta au moment de la rédaction).

Synthèse de la recommandation :

| Profil d'organisation | Recommandation |
|---|---|
| PME / startup, équipes 100 % GitLab, besoin simple secrets CI/CD | **GitLab Secrets Manager** (Ultimate) une fois en GA |
| Grand groupe privé, multi-cloud, multi-outils (Jenkins, K8s, Terraform…) | **OpenBao auto-hébergé** |
| Secteur public, OIV/OSE, contraintes ANSSI/SecNumCloud, souveraineté | **OpenBao auto-hébergé**, possiblement en architecture hybride |
| Organisation déjà sous GitLab Premium, prête à migrer Ultimate | Évaluer **OpenBao** d'abord ; GitLab SM si maturité atteinte |
| Architecture hybride et progressive | **OpenBao auto-hébergé + intégration GitLab Vault** (Premium suffit) |

---

## 2. Présentation des deux solutions

### 2.1 OpenBao

OpenBao est un fork open source de HashiCorp Vault, créé en novembre 2023 à la suite du changement de licence de Vault (passage à la BSL). Il est piloté par la **Linux Foundation** (sous l'égide de l'OpenSSF) et publié sous licence **MPL 2.0**, c'est-à-dire libre d'utilisation, modification et redistribution, y compris pour des usages commerciaux.

Le projet a été forké à partir de Vault 1.14 (dernière version sous MPL 2.0) et a depuis évolué de manière autonome. Parmi les avancées notables en 2026 : ajout des **Namespaces** (auparavant réservés à Vault Enterprise) et de la **horizontal read scalability** (OpenBao 2.5.0, février 2026), permettant aux nœuds standby HA de traiter localement les opérations de lecture.

**Caractéristiques techniques clés :**

- Stockage chiffré de secrets statiques (KV v1/v2 avec versioning)
- Génération de **secrets dynamiques** à la volée (bases de données, cloud, Kubernetes, SSH, etc.)
- Moteur **PKI** : autorité de certification, émission de certificats X.509 dynamiques
- Moteur **Transit** : « encryption as a service », signature, HMAC, génération de bytes aléatoires
- **Leases** et révocation en cascade des secrets
- Plus de 20 méthodes d'authentification (LDAP, OIDC, JWT, AppRole, Kubernetes, AWS IAM, etc.)
- API HTTP, CLI, agent local (`bao agent`), CSI driver pour Kubernetes
- Réplication, HA, intégration HSM

### 2.2 GitLab Secret Manager

GitLab Secret Manager est la nouvelle solution **native** de gestion de secrets de GitLab, conçue pour être utilisée directement depuis l'expérience GitLab (UI similaire aux CI Variables). Selon la documentation officielle et l'ADR 007 publiée dans le Handbook GitLab, le service repose techniquement sur **OpenBao** en backend.

**Statut au moment de la rédaction (mai 2026) :**

- Closed beta démarrée avec GitLab 18.8 (project-level)
- Group-level Secrets Manager introduit en GitLab 18.10
- Marqué « experiment / beta », non recommandé pour la production
- Les secrets stockés en beta **ne seront pas conservés** lors du passage en GA
- **Disponibilité limitée au tier Ultimate** (selon docs GitLab à date)

**Architecture exposée par GitLab :**

- Chaque top-level tenant (généralement le propriétaire d'un repo) possède un namespace OpenBao dédié
- Une *auth mount* OIDC par tenant pour autoriser les pipelines
- Une *role* OpenBao par projet GitLab
- Un moteur **KVv2** par projet pour stocker ses secrets
- Les pipelines GitLab Runner récupèrent les secrets via un *ID token* JWT (OIDC)

À noter : à côté du *Secrets Manager natif*, GitLab Premium et Ultimate proposent depuis longtemps une **intégration externe avec HashiCorp Vault** (et donc compatible OpenBao), qui reste la voie la plus mature aujourd'hui pour injecter des secrets dans les pipelines.

---

## 3. Analyse fonctionnelle / technique

### 3.1 Moteurs de secrets et capacités

| Capacité | OpenBao (self-hosted) | GitLab Secrets Manager |
|---|---|---|
| Secrets statiques KV (v1/v2) | Oui, complet | Oui (KVv2 par projet) |
| Secrets dynamiques (DB, cloud, K8s) | Oui (>15 moteurs) | Non exposé en beta |
| PKI / émission de certificats X.509 | Oui, complet | Non exposé |
| Transit (encryption as a service) | Oui | Non exposé |
| TOTP / SSH / Nomad / etc. | Oui | Non exposé |
| Versioning de secret | Oui (KVv2) | Oui (via KVv2) |
| Lease et révocation cascade | Oui | Limité à l'usage CI/CD |
| Namespaces multi-tenant | Oui (depuis 2.x) | Implicite (1 namespace par tenant GitLab) |

**Verdict :** OpenBao expose **toute** sa surface fonctionnelle. GitLab Secret Manager n'expose pour l'instant qu'une **fraction** (essentiellement du KV par projet/groupe) — c'est volontaire : GitLab a fait le choix de simplifier l'expérience et de couvrir d'abord le cas d'usage CI/CD.

### 3.2 Authentification et autorisation

OpenBao supporte nativement : Token, AppRole, LDAP, OIDC, JWT, Kubernetes, AWS IAM, Azure, GCP, TLS Certificates, Userpass, RADIUS, GitHub, Okta, etc. Les politiques (`policies`) HCL/JSON permettent un RBAC très fin par chemin (`path "secret/data/app1/*"`).

GitLab Secret Manager, en beta, repose principalement sur **OIDC** via les *ID tokens* du Runner GitLab. L'autorisation est calquée sur les rôles GitLab (Owner, Maintainer, Developer…) au niveau projet/groupe. C'est très simple à utiliser, mais beaucoup moins flexible que les policies OpenBao natives.

### 3.3 Modèle de déploiement et exploitation

| Critère | OpenBao | GitLab Secrets Manager |
|---|---|---|
| Hébergement | Vous (on-prem, cloud, K8s, etc.) | GitLab (intégré à votre instance GitLab self-managed ou SaaS) |
| Haute disponibilité | À configurer (Raft, Consul, etc.) | Géré par la chart GitLab |
| Sauvegardes / DR | À votre charge | Inclus dans la stratégie GitLab |
| Mises à jour | Vous suivez les releases OpenBao | Intégré au cycle GitLab |
| Upgrade path | Standard OpenBao | Suit GitLab |
| Compétences requises | Élevées (Vault/OpenBao operator) | Faibles à modérées |

### 3.4 Évolutivité

OpenBao 2.5+ apporte la **horizontal read scalability** (nœuds standby HA servant les lectures), et les **Namespaces**, qui rapprochent l'OSS des capacités historiques de Vault Enterprise. Pour des charges très importantes ou multi-régions, OpenBao s'avère plus mature.

GitLab Secrets Manager hérite techniquement de ces propriétés, mais en pratique, GitLab encapsule l'instance OpenBao : vous n'avez pas le même niveau de contrôle sur le tuning, le sharding ou les options de réplication.

---

## 4. Intégration CI/CD et DevOps

### 4.1 Intégration avec GitLab

**Option A — GitLab Premium + OpenBao auto-hébergé** (intégration Vault) :
- L'intégration `vault: …` dans `.gitlab-ci.yml` fonctionne avec OpenBao (API compatible Vault)
- Authentification via JWT/OIDC du Runner
- Injection des secrets en variables d'environnement de job
- Disponible **à partir du tier Premium**

**Option B — GitLab Ultimate + GitLab Secrets Manager** (natif) :
- Déclaration des secrets directement dans l'UI GitLab (similaire aux CI Variables)
- Bloc `secrets:` dans `.gitlab-ci.yml`, sans configuration d'auth complexe
- Ne nécessite **aucun déploiement externe**
- Disponible **uniquement en Ultimate** (et en beta à date)

### 4.2 Hors écosystème GitLab

OpenBao s'intègre nativement avec : Kubernetes (via CSI Secret Store, Agent Injector, Vault Secrets Operator), Terraform/OpenTofu, Ansible, Jenkins, Docker, ArgoCD, Crossplane, etc. C'est un standard de fait des plateformes cloud-native.

GitLab Secrets Manager **n'a pas vocation à servir des consommateurs hors GitLab** : c'est un service interne à la plateforme. Si vous avez d'autres outils CI/CD (Jenkins, GitHub Actions internes, ArgoCD…), ils ne s'y connecteront pas naturellement.

### 4.3 Workflow développeur

GitLab Secrets Manager remporte la palme sur l'UX : un développeur autorisé crée un secret depuis l'UI du projet, l'utilise dans un pipeline en quelques secondes, et profite de la gouvernance native GitLab (audit, MR, etc.). OpenBao impose un saut de contexte (CLI/UI séparée, gestion des policies).

---

## 5. Sécurité et conformité

### 5.1 Sécurité native

Les deux solutions héritent de la même base technique. Donc, sur les fondamentaux : chiffrement AES-256-GCM des secrets, scellement (seal/unseal), shamir secret sharing, support HSM (via PKCS#11), audit log structuré, rotation des clés de chiffrement (rekey/rotate).

Différences :
- OpenBao expose toutes ces fonctions, paramétrables finement
- GitLab Secrets Manager hérite de ces fonctions mais les expose partiellement via la chart GitLab et son tooling

### 5.2 Auditabilité

OpenBao produit un **audit log** détaillé de chaque opération (lecture, écriture, login, lease, …), envoyable vers fichier, syslog, ou socket. C'est un élément clé pour les certifications ISO 27001, SOC 2, PCI-DSS, HDS.

GitLab Secrets Manager s'appuie sur :
- Les audit events natifs GitLab (Ultimate)
- Les logs de l'instance OpenBao sous-jacente (accessibles si self-managed)

Pour une organisation soumise à des obligations d'audit fortes (banque, santé, secteur public), OpenBao offre plus de granularité et de contrôle sur la chaîne d'audit.

### 5.3 Certifications et conformité

OpenBao n'a, à date, **pas encore** de certifications propres (le projet est jeune), mais il hérite du patrimoine Vault 1.14, qui était audité et utilisé dans des environnements certifiés FedRAMP, PCI, HIPAA. La conformité dépend de votre déploiement et de votre dossier de conformité.

GitLab (instance Ultimate) bénéficie des certifications de la plateforme GitLab : SOC 2 Type II, ISO 27001, etc. Secrets Manager hérite de ce périmètre, mais étant en beta, il n'est pas inclus dans les engagements contractuels.

### 5.4 Souveraineté et secteur public

Pour les administrations françaises ou européennes soumises à la doctrine *Cloud au Centre*, RGS, ANSSI, ou SecNumCloud :

- **OpenBao** est un projet de la Linux Foundation, sous licence MPL 2.0, sans dépendance à un éditeur commercial. C'est l'option la plus cohérente avec une exigence de souveraineté logicielle.
- **GitLab** est une société américaine cotée au Nasdaq. GitLab.com (SaaS) ne répond pas aux exigences SecNumCloud. GitLab self-managed peut s'inscrire dans un cloud souverain (3DS Outscale, S3NS, etc.).
- Pour le cas spécifique « hôpital, ministère, OIV/OSE » : OpenBao auto-hébergé sur infrastructure souveraine est plus défendable qu'une dépendance à GitLab Ultimate + Secrets Manager.

### 5.5 Chiffrement et HSM

OpenBao supporte les HSM via PKCS#11 (auto-unseal HSM), Cloud KMS (AWS KMS, Azure Key Vault, GCP KMS) pour le seal. Ces fonctions sont disponibles dans le projet open source (héritage du fork pré-BSL et contributions communautaires).

GitLab Secrets Manager hérite techniquement de ces capacités, mais leur exposition via la chart GitLab n'est pas garantie au même niveau.

---

## 6. Coût et licensing

### 6.1 Licences

| | OpenBao | GitLab Secret Manager |
|---|---|---|
| Licence | MPL 2.0 (open source) | Licence GitLab Ultimate (propriétaire, EE) |
| Gouvernance | Linux Foundation / OpenSSF | GitLab Inc. (Nasdaq : GTLB) |
| Verrouillage éditeur | Non | Oui (couplé à GitLab) |

### 6.2 Coûts directs

**OpenBao :**
- Licence : **0 €**
- Coûts indirects : infrastructure (VM/K8s), exploitation, support (interne ou via prestataire), formation
- Support commercial possible via des intégrateurs tiers (IBM, bespinian, etc.) ou via Vault Enterprise si vous voulez payer HashiCorp (mais alors vous quittez OpenBao)

**GitLab :**
- **Premium :** ~29 $/user/mois (SaaS), ~19 $/user/mois (self-managed) — inclut l'intégration Vault externe, **PAS** le Secrets Manager natif
- **Ultimate :** ~99 $/user/mois — inclut le Secrets Manager natif (en beta), plus toute la sécurité avancée (SAST, DAST, dependency scanning…)
- Le saut Premium → Ultimate représente **+70 $/user/mois**, soit ~840 $/user/an

### 6.3 Exemple chiffré (organisation de 100 développeurs)

| Scénario | Coût annuel approximatif |
|---|---|
| GitLab Premium + OpenBao auto-hébergé | 100 × 29 × 12 = **34 800 $** + ~30 à 80 k€ d'exploitation OpenBao = **~65–115 k€/an** |
| GitLab Ultimate + Secrets Manager natif | 100 × 99 × 12 = **118 800 $/an** (~110 k€), exploitation incluse |
| OpenBao seul (CI/CD non-GitLab) | ~30 à 80 k€/an d'exploitation |

À noter : le passage à Ultimate apporte **bien plus** que le Secrets Manager (sécurité applicative, compliance pipelines, Duo Enterprise, etc.). Le surcoût ne se justifie pas pour le seul Secrets Manager.

### 6.4 TCO et risques

- **OpenBao** : prévisible, indépendant du nombre d'utilisateurs, mais consomme des compétences DevSecOps. Risque principal : maturité du projet (jeune en tant qu'entité indépendante) et bus factor de la communauté.
- **GitLab Ultimate + SM** : prévisible, scale avec le nombre de devs, mais crée une dépendance à GitLab. Risque principal : verrouillage et coût croissant à mesure que les équipes grossissent.

---

## 7. Comparatif synthétique

| Critère | OpenBao | GitLab Secret Manager |
|---|---|---|
| Licence | MPL 2.0 (libre) | GitLab Ultimate (propriétaire) |
| Coût direct | 0 € | ~99 $/user/mois (Ultimate) |
| Maturité | Élevée (héritage Vault) | Faible (beta) |
| Couverture fonctionnelle | Complète (KV, PKI, transit, dyn. secrets, …) | KV / cas d'usage CI/CD |
| UX pour développeur GitLab | Moyenne (outils séparés) | Excellente (UI intégrée) |
| Intégration hors-GitLab | Excellente | Inadaptée |
| RBAC | Très fin (policies HCL) | Calqué sur les rôles GitLab |
| Audit | Audit log complet | Audit events GitLab |
| HSM, KMS | Oui | Hérité, peu exposé |
| Souveraineté | Forte (Linux Foundation) | Dépend de l'hébergement GitLab |
| Compétences requises | Élevées | Faibles |
| Verrouillage éditeur | Aucun | Fort (GitLab Inc.) |
| Cas idéal | Multi-outils, multi-cloud, secteur réglementé | 100 % GitLab, équipes produit, démarrage rapide |

---

## 8. Recommandations selon votre contexte

### Si vous êtes une **entreprise privée**

- **Équipes <50, mono-stack GitLab, faible maturité DevSecOps** → GitLab Secrets Manager (Ultimate) une fois la GA stable. Profitez du package Ultimate pour la sécurité applicative associée.
- **Équipes >100, multi-cloud, multi-outils (Jenkins, ArgoCD, Terraform…)** → OpenBao auto-hébergé. Intégrez-le à GitLab via l'intégration Vault (Premium suffit).
- **Équipes 50–100 en croissance, déjà sous Premium** → restez sur Premium + OpenBao auto-hébergé. C'est l'architecture la plus flexible et la moins coûteuse à moyen terme.

### Si vous êtes une **organisation publique**

- **Contraintes SecNumCloud, ANSSI, RGS, RGPD strict** → OpenBao auto-hébergé sur cloud souverain ou on-premise. Évitez la dépendance fonctionnelle à GitLab SaaS pour vos secrets.
- **OIV/OSE (directive NIS2)** → OpenBao auto-hébergé, idéalement avec HSM et audit log redirigé vers SIEM. Préparez le dossier de conformité.
- **Établissement public sans contrainte forte de souveraineté** → l'option GitLab Ultimate + Secrets Manager est envisageable, mais à ne pas prendre uniquement pour le SM (le saut Ultimate doit se justifier par les autres briques sécurité).

### Architecture hybride recommandée pour la plupart des organisations

```
┌──────────────────────────────────────────────────┐
│           OpenBao Cluster (self-hosted)          │
│   - KV / PKI / Transit / Dynamic secrets         │
│   - Audit log → SIEM                             │
│   - Auth : OIDC, K8s, AppRole, LDAP              │
└──────────────────────────────────────────────────┘
            ▲              ▲              ▲
            │              │              │
       (OIDC/JWT)      (K8s SA)       (AppRole)
            │              │              │
   ┌────────┴──────┐  ┌────┴─────┐  ┌─────┴──────┐
   │  GitLab CI    │  │ K8s pods │  │  Jenkins,   │
   │  (Premium)    │  │  / Argo  │  │  Terraform  │
   └───────────────┘  └──────────┘  └─────────────┘
```

Cette architecture vous garantit :
- Indépendance vis-à-vis du tier GitLab choisi
- Couverture de tous vos consommateurs (CI, Kubernetes, IaC, autres CI/CD)
- Souveraineté technique
- Coût maîtrisé (Premium suffit côté GitLab)

---

## 9. Points de vigilance et limites de l'étude

- **GitLab Secrets Manager est en beta** au moment de la rédaction (mai 2026). Tout choix engageant doit attendre la GA et lire attentivement les engagements contractuels de GitLab.
- **Le tier exact** (Premium vs Ultimate) pour le Secrets Manager natif peut évoluer. La documentation actuelle indique **Ultimate** ; ce point est à confirmer auprès de votre account manager GitLab avant tout engagement budgétaire.
- **OpenBao** reste un projet jeune en tant qu'entité indépendante (depuis fin 2023). Bien que techniquement mature (hérité de Vault), sa trajectoire long terme dépend de l'engagement continu de la communauté et de la Linux Foundation.
- L'étude ne couvre pas en détail les **comparaisons avec d'autres acteurs** (HashiCorp Vault Enterprise, AWS Secrets Manager, Azure Key Vault, Google Secret Manager, CyberArk Conjur, Doppler, Infisical), qui peuvent être pertinents selon votre contexte.

---

## 10. Conclusion

Le « duel » OpenBao vs GitLab Secret Manager est en partie un faux débat : **GitLab Secret Manager EST OpenBao**, packagé et opéré par GitLab pour les clients Ultimate. La vraie question est celle du **niveau de contrôle** et de **l'écosystème** :

- Vous voulez une intégration plug-and-play, vos équipes vivent dans GitLab, et vous avez le budget Ultimate → **GitLab Secret Manager** (à GA).
- Vous voulez le contrôle, l'écosystème ouvert et la souveraineté → **OpenBao auto-hébergé**.

Dans le doute, l'option OpenBao auto-hébergé reste **la plus flexible et la plus pérenne**, car elle ne ferme aucune porte : vous pourrez toujours migrer vers GitLab SM plus tard si le besoin se confirme, alors que l'inverse (migrer hors de GitLab SM) sera coûteux en temps et en risque.

---

## Sources

- [OpenBao – site officiel](https://openbao.org/)
- [OpenBao vs HashiCorp Vault: The Secrets Management Showdown Every DevOps Team Needs to Read in 2026 – Medium](https://lalatenduswain.medium.com/openbao-vs-hashicorp-vault-the-secrets-management-showdown-every-devops-team-needs-to-read-in-2026-458ae0d9a408)
- [The Guide to OpenBao – Part 1 (blog.stderr.at)](https://blog.stderr.at/openshift-platform/security/secrets-management/openbao/2026-02-11-openbao-part-1-introduction/)
- [OpenBao: When to Choose the Open Source Vault Alternative – bespinian](https://bespinian.io/en/blog/openbao-os-vault-alternative/)
- [GitLab Native Secrets Manager Announcement – GitLab Blog](https://about.gitlab.com/blog/gitlab-native-secrets-manager-to-give-software-supply-chain-security-a-boost/)
- [GitLab Secrets Manager – GitLab Docs (CI/CD)](https://docs.gitlab.com/ci/secrets/secrets_manager/)
- [GitLab Secrets Manager (OpenBao) – GitLab Admin Docs](https://docs.gitlab.com/administration/secrets_manager/)
- [GitLab Secrets Manager ADR 007: Use OpenBao – GitLab Handbook](https://handbook.gitlab.com/handbook/engineering/architecture/design-documents/secret_manager/decisions/007_openbao/)
- [OpenBao chart – GitLab Docs](https://docs.gitlab.com/charts/charts/openbao/)
- [OpenBao @ GitLab – FOSDEM '25 talk](https://openbao.org/blog/cipherboy-fosdem-25-talk/)
- [Transit secrets engine – OpenBao docs](https://openbao.org/docs/secrets/transit/)
- [PKI secrets engine – OpenBao docs](https://openbao.org/docs/secrets/pki/)
- [GitLab Pricing 2026 – costbench.com](https://costbench.com/software/developer-tools/gitlab/)
- [GitLab Pricing 2026 – eesel AI](https://www.eesel.ai/blog/gitlab-pricing)
- [GitLab Pricing Plans and Tiers Compared (2026) – CompareTiers](https://comparetiers.com/tools/gitlab)
- [GitLab Official Pricing](https://about.gitlab.com/pricing/)
- [Use external secrets in CI/CD – GitLab Docs](https://docs.gitlab.com/ci/secrets/)
