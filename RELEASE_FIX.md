# Fix para Releases de wayu

## Problema Identificado

Los commits de release existen pero los tags no:
- Commits: `chore: release v3.6.0`, `v3.7.0`, `v3.7.1`, `v3.8.0`
- Tags: Solo existe `v3.5.0` y anteriores

Esto indica que el workflow `bump.yml` crea el commit pero falla al crear/pushear el tag.

## Causas Probables

1. **El commit falla silenciosamente** - Si no hay cambios nuevos, `git commit` falla y el tag nunca se crea
2. **Problemas de token** - `GITHUB_TOKEN` tiene limitaciones para workflows anidados
3. **Race condition** - El push del tag ocurre antes de que el commit esté disponible remotamente

## Solución Implementada

Se modificó `.github/workflows/bump.yml`:

```yaml
# Antes (fallaba si el commit no tenía cambios):
git commit -m "chore: release ${{ steps.version.outputs.VERSION }}"
git tag ${{ steps.version.outputs.VERSION }}

# Después (maneja errores):
git commit -m "chore: release ${{ steps.version.outputs.VERSION }}" || echo "Commit may already exist"
git tag ${{ steps.version.outputs.VERSION }} || { echo "Tag may already exist"; ... }
git push origin ${{ steps.version.outputs.VERSION }} --force
```

## Para Debuggear

Revisar logs de ejecuciones pasadas:

```bash
gh run list --repo dvrd/wayu --workflow=bump.yml --limit=10
gh run view <ID> --repo dvrd/wayu --log
```

## Plan para v3.9.0

### Opción 1: Push normal (con fixes aplicados)
```bash
git add -A
git commit -m "feat: add doctor command with auto-fix and fuzzy plugin matching"
git push origin main
```

El workflow debería ejecutarse automáticamente.

### Opción 2: Si el workflow sigue fallando
Crear el tag manualmente:
```bash
# Actualizar versión
sed -i 's/VERSION :: "[^"]*"/VERSION :: "3.9.0"/' src/main.odin

# Generar changelog
git cliff --tag v3.9.0 -o CHANGELOG.md

# Commit y tag manual
git add -A
git commit -m "chore: release v3.9.0"
git tag v3.9.0
git push origin main
git push origin v3.9.0

# El release.yml se ejecutará automáticamente por el tag push
```

### Opción 3: Usar PAT (más confiable)
Si `GITHUB_TOKEN` sigue dando problemas:

1. Crea un Personal Access Token (classic) con scopes: `repo`, `workflow`
2. Guárdalo como `RELEASE_TOKEN` en Settings → Secrets → Actions
3. Modifica el workflow para usar:
   ```yaml
   token: ${{ secrets.RELEASE_TOKEN }}
   ```

## Verificación Post-Release

Después del release, verificar:

```bash
# Que el tag exista
git tag -l "v3.9*"

# Que el release tenga assets
curl -s https://api.github.com/repos/dvrd/wayu/releases/latest | jq '.tag_name, .assets[].name'

# Que homebrew esté actualizado
curl -s https://raw.githubusercontent.com/dvrd/homebrew-wayu/main/Formula/wayu.rb | grep "version"
```
