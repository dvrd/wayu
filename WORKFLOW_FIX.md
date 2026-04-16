# Análisis y Fix del Workflow de Release

## Problema Raíz Identificado

Los commits de release existen pero los tags no:
- ✅ `chore: release v3.6.0` (commit d32f0d7)
- ✅ `chore: release v3.7.0` (commit 010c773)  
- ✅ `chore: release v3.7.1` (commit 6039f7d)
- ✅ `chore: release v3.8.0` (commit ebbfc8d)
- ❌ Tags v3.6.0, v3.7.0, v3.7.1, v3.8.0 no existen
- ✅ Solo v3.5.0 y anteriores funcionan

## Causa del Problema

El workflow `.github/workflows/bump.yml` tiene esta condición:

```yaml
if: "!startsWith(github.event.head_commit.message, 'chore: release')"
```

Esto evita loops infinitos, pero crea un problema de recuperación:

1. Workflow ejecuta → Crea commit "chore: release v3.8.0"
2. Si el `git tag` falla por cualquier razón (token, permisos, red)
3. El commit queda como HEAD en main
4. El próximo push NO ejecuta el workflow (porque el último commit empieza con "chore: release")
5. Resultado: Commit existe, tag no existe, workflow nunca se reintenta

Esto se ve en el historial de CI:
```
160c99e ci: merge build+release into bump workflow to fix GITHUB_TOKEN 403
9bbe448 ci: pass tag_name explicitly to action-gh-release when dispatched  
8e5892d ci: fix release.yml not triggering after tag push from bump.yml
```

Hubo múltiples intentos de arreglar el problema sin éxito.

## Solución Implementada

### 1. Detección de Tags Perdidos

El workflow ahora detecta automáticamente si un tag está "perdido":

```yaml
# Check if we need to recreate a missing tag (auto-detect)
if [ "${{ startsWith(github.event.head_commit.message, 'chore: release') }}" = "true" ]; then
  COMMIT_VERSION=$(echo "${{ github.event.head_commit.message }}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
  if [ -n "$COMMIT_VERSION" ]; then
    if ! git rev-parse "$COMMIT_VERSION" >/dev/null 2>&1; then
      echo "Tag $COMMIT_VERSION missing but commit exists — will recreate tag"
      VERSION="$COMMIT_VERSION"
      RECREATE_TAG="true"
    fi
  fi
fi
```

### 2. Recreación Manual de Tags

Nueva opción `workflow_dispatch` para recrear tags específicos:

```yaml
workflow_dispatch:
  inputs:
    recreate_tag:
      description: 'Recreate a missing tag (e.g., v3.8.0)'
      required: false
      default: ''
      type: string
```

Uso: GitHub → Actions → Bump Version & Release → Run workflow → `recreate_tag: v3.8.0`

### 3. Manejo de Errores Mejorado

El paso de commit/tag ahora maneja errores graceful:

```bash
# Solo commit si no estamos recreando
if [ "${{ steps.version.outputs.RECREATE_TAG }}" != "true" ]; then
  git commit -m "chore: release ${{ steps.version.outputs.VERSION }}" || echo "Commit exists"
else
  echo "Recreating tag for existing commit"
fi

# Force delete y recreate del tag si es necesario
if [ "${{ steps.version.outputs.RECREATE_TAG }}" = "true" ]; then
  git tag -d ${{ steps.version.outputs.VERSION }} 2>/dev/null || true
  git push origin :refs/tags/${{ steps.version.outputs.VERSION }} 2>/dev/null || true
fi
git tag ${{ steps.version.outputs.VERSION }}
git push origin ${{ steps.version.outputs.VERSION }}
```

### 4. Checkout Correcto para Recreación

Cuando recreamos un tag, usamos el SHA actual en lugar de la ref:

```yaml
ref: ${{ inputs.recreate_tag != '' && github.sha || github.ref }}
```

## Cómo Recuperar Tags Perdidos (v3.6.0 - v3.8.0)

### Opción 1: Recrear Manualmente (Recomendado)

Ir a GitHub → Actions → Bump Version & Release → Run workflow:
- `recreate_tag: v3.8.0`
- Click "Run workflow"

Repetir para v3.6.0, v3.7.0, v3.7.1 si es necesario.

### Opción 2: Push Normal de v3.9.0

Hacer push del código actual:

```bash
git add -A
git commit -m "feat: add doctor command with auto-fix and fuzzy plugin matching

- Add wayu doctor for health checks with --fix and --json
- Add fuzzy matching for plugin commands  
- Add interactive selection for multiple plugin matches
- Add wayu config scan to detect inline scripts in .zshrc
- Add wayu config edit to edit wayu.toml declarative config
- Update turbo export to include tools.zsh and extra.zsh
- Update all documentation"

git push origin main
```

El workflow automáticamente:
1. Detectará que v3.9.0 es la siguiente versión
2. Creará el commit "chore: release v3.9.0" (si no existe)
3. Creará el tag v3.9.0
4. Si falla, la próxima ejecución auto-detectará el tag perdido

## Verificación Post-Fix

```bash
# Verificar tags
git fetch --tags
git tag -l | grep "v3.[6789]"

# Verificar releases
curl -s https://api.github.com/repos/dvrd/wayu/releases | jq '.[].tag_name'
```

## Cambios al Workflow

Archivo: `.github/workflows/bump.yml`

| Cambio | Descripción |
|--------|-------------|
| Auto-detect lost tags | Si el commit es "chore: release" pero el tag no existe, lo recrea |
| `recreate_tag` input | Permite recrear tags manualmente via workflow_dispatch |
| Error handling | Usa `|| echo` para continuar si commit ya existe |
| Force tag push | Elimina tag remoto si existe antes de crearlo |
| Conditional commit | No hace commit si estamos recreando un tag |

## Testing

Para testear el workflow sin hacer un release real:

```bash
# Simular ejecución local
git cliff --bumped-version  # Ver qué versión detecta

# Verificar lógica de recreate_tag
export GITHUB_EVENT_HEAD_COMMIT_MESSAGE="chore: release v3.8.0"
echo $GITHUB_EVENT_HEAD_COMMIT_MESSAGE | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+'
```
