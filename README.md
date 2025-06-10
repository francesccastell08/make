# Terraform & Packer Management Script

Script de automatización para gestionar infraestructura con Terraform y builds con Packer de forma eficiente y segura.

## Características

- **Gestión multi-entorno**: Soporte para dev, pre, pro
- **Modo interactivo**: Selección de recursos específicos con interfaz CLI
- **Limpieza automática**: Gestión de archivos temporales con traps
- **Validaciones robustas**: Verificación de dependencias y estructura
- **Logging estructurado**: Mensajes informativos, warnings y errores
- **Manejo de errores**: Exit codes apropiados y cleanup automático

## Prerrequisitos

### Herramientas requeridas
- **Terraform**: >= 1.0
- **Packer**: Para builds de AMIs
- **jq**: Requerido para modo interactivo
- **dos2unix**: Para procesamiento de templates (opcional)

### Instalación de dependencias

```bash
# Ubuntu/Debian
sudo apt-get install terraform packer jq dos2unix

# macOS
brew install terraform packer jq dos2unix

# CentOS/RHEL
sudo yum install terraform packer jq dos2unix
```

## Estructura del proyecto

```
├── environments/
│   ├── dev/
│   ├── pre/
│   └── pro/
├── templates/
│   └── *.tpl
├── make
└── README.md
```

## Uso

### Comandos Terraform

#### Comandos básicos
```bash
# Inicializar entorno
./make init <environment>

# Generar plan
./make plan <environment>

# Aplicar cambios
./make apply <environment>
```

#### Targeting específico
```bash
# Target específico
./make plan pre -target=module.alb.aws_lb.main

# Modo interactivo (requiere jq)
./make plan pre -target
```

#### Flags adicionales
```bash
# Con flags de Terraform
./make plan dev -var="instance_type=t3.large" -refresh=false

# Auto-approve para apply
./make apply pro -auto-approve
```

### Comandos Packer

```bash
# Build básico
./make build webapp

# Build con variables personalizadas
./make build api -var="ami_name=custom-api-v2"

# Build con múltiples variables
./make build frontend -var="instance_type=t3.medium" -var="region=eu-west-1"
```

## Modo Interactivo

El modo interactivo permite seleccionar recursos específicos de forma visual:

```bash
./make plan pre -target
```

### Funcionalidades del modo interactivo

1. **Análisis automático**: Genera plan y analiza cambios
2. **Lista coloreada**: 
   - 🟢 Verde: Recursos a crear
   - 🟡 Amarillo: Recursos a actualizar  
   - 🔴 Rojo: Recursos a eliminar
3. **Opciones de selección**:
   - Número: Aplicar recurso específico
   - `a`: Aplicar todos los cambios
   - `c`: Cancelar operación

## Gestión de archivos temporales

El script gestiona automáticamente:
- `tmp.tfplan`: Archivos de plan de Terraform
- `tmp.tfplan.json`: Plans convertidos a JSON
- Limpieza en directorios de entorno
- Cleanup automático al interrumpir (Ctrl+C)

## Validaciones

### Entornos
- Verifica existencia de directorio `environments/<env>/`
- Lista entornos disponibles en caso de error

### Templates
- Procesa automáticamente archivos `*.tpl` en `templates/`
- Convierte line endings con `dos2unix`

### Dependencias
- Verifica instalación de herramientas requeridas
- Proporciona instrucciones de instalación específicas por OS

## Logging y errores

### Tipos de mensajes
```bash
INFO: Mensaje informativo
WARNING: Advertencia (stderr)
ERROR: Error crítico (stderr)
```

### Exit codes
- `0`: Éxito
- `1`: Error general
- `130`: Interrupción por usuario (Ctrl+C)
- `143`: Terminación por señal


## Troubleshooting

### Error: "jq no está instalado"
```bash
# Instalar jq según tu sistema operativo
sudo apt-get install jq  # Ubuntu/Debian
brew install jq          # macOS
sudo yum install jq      # CentOS/RHEL
```

### Error: "Entorno no encontrado"
```bash
# Verificar estructura de directorios
ls -la environments/

# Crear entorno faltante
mkdir -p environments/dev
```

### Error: "Template Packer no encontrado"
```bash
# Listar templates disponibles
find . -name "*.pkr.hcl" -o -name "*.json"

# Verificar ruta del template
./make build ./packer/webapp.pkr.hcl
```