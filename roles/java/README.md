# Rôle Ansible : java

Installe une version spécifique d'**OpenJDK** (via dépôts distro) et gère
l'**ajout / suppression** de certificats dans le keystore `cacerts` du JDK via `keytool`.

## Plateformes supportées

- Debian 12 (bookworm)
- Debian 13 (trixie)
- Rocky Linux 9

## Variables principales (`defaults/main.yml`)

| Variable | Défaut | Description |
|---|---|---|
| `java_version` | `"17"` | Version OpenJDK (ex: `11`, `17`, `21`) |
| `java_jdk` | `true` | `true` = JDK complet, `false` = JRE headless |
| `java_home` | `""` | Force JAVA_HOME (sinon auto-détecté) |
| `java_cacerts_storepass` | `"changeit"` | Mot de passe du keystore cacerts |
| `java_certs_present` | `[]` | Certificats à ajouter (`alias` + `src`) |
| `java_certs_absent` | `[]` | Alias de certificats à supprimer |

## Mapping des paquets

| OS | JDK | JRE |
|---|---|---|
| Debian 12/13 | `openjdk-<ver>-jdk` | `openjdk-<ver>-jre-headless` |
| Rocky 9 | `java-<ver>-openjdk-devel` | `java-<ver>-openjdk-headless` |

## Gestion des certificats

L'ajout est **idempotent** : le rôle compare l'empreinte SHA-256 du certificat
source à celle de l'alias présent dans le cacerts. Il (ré)importe uniquement si
l'alias est absent ou si le certificat a changé. La suppression ne s'exécute que
si l'alias existe.

## Exemple d'utilisation

```yaml
- hosts: all
  become: true
  roles:
    - role: java
      vars:
        java_version: "21"
        java_jdk: true
        java_certs_present:
          - alias: my-internal-ca
            src: files/my-internal-ca.crt
        java_certs_absent:
          - old-internal-ca
```

Les fichiers `.crt` / `.pem` doivent être disponibles sur le contrôleur Ansible
(par défaut dans `files/` du playbook ou du rôle).
