#!/bin/bash

set -euo pipefail

###############################################################
# Función de ayuda mejorada
function help() {
    cat <<EOF
COMANDOS TERRAFORM:

	Generals
		./make <init|plan|apply> <environment> [flags]
		
	Targets
		./make plan pre -target=module.alb.aws_lb.main
		./make plan pre -target 


COMANDOS PACKER:
	./make build <app> [flags]

		./make build webapp
		./make build api -var="ami_name=custom-api-v2"


NOTAS:
	- Entornos disponibles: dev, pre, pro (deben existir en ./environments/)
	- El modo interactivo (-target sin valor) requiere 'jq' instalado
	- Los archivos .tpl en templates/ se procesan automáticamente

EOF
    exit 1
}

###############################################################
# Funciones auxiliares mejoradas
function header() {
    echo ""
    echo "========================================================="
    echo "$1"
    echo "========================================================="
}

function footer() {
    echo "========================================================="
    echo "Operación completada"
    echo "========================================================="
    echo ""
}

function log_info() {
    echo "INFO: $1"
}

function log_warning() {
    echo "WARNING: $1" >&2
}

function log_error() {
    echo "ERROR: $1" >&2
}

###############################################################
# Variables globales para archivos temporales
PLAN_FILE="tmp.tfplan"
PLAN_JSON="tmp.tfplan.json"
CURRENT_ENV=""

# Función mejorada para limpiar archivos temporales
function cleanup_temp_files() {
    local files_to_clean=()
    
    # Archivos temporales en el directorio actual
    [[ -f "$PLAN_FILE" ]] && files_to_clean+=("$PLAN_FILE")
    [[ -f "$PLAN_JSON" ]] && files_to_clean+=("$PLAN_JSON")
    
    # Archivos temporales en el directorio del entorno si existe
    if [[ -n "$CURRENT_ENV" && -d "environments/$CURRENT_ENV" ]]; then
        [[ -f "environments/$CURRENT_ENV/$PLAN_FILE" ]] && files_to_clean+=("environments/$CURRENT_ENV/$PLAN_FILE")
        [[ -f "environments/$CURRENT_ENV/$PLAN_JSON" ]] && files_to_clean+=("environments/$CURRENT_ENV/$PLAN_JSON")
    fi
    
    # Limpiar archivos encontrados
    if (( ${#files_to_clean[@]} > 0 )); then
        log_info "Limpiando archivos temporales: ${files_to_clean[*]}"
        rm -f "${files_to_clean[@]}"
    fi
}

# Función para limpiar y salir
function cleanup_and_exit() {
    local exit_code=${1:-0}
    cleanup_temp_files
    exit "$exit_code"
}

# Configurar trap global para limpieza automática
trap 'cleanup_temp_files' EXIT
trap 'log_warning "Script interrumpido por el usuario"; cleanup_and_exit 130' INT
trap 'log_error "Script terminado inesperadamente"; cleanup_and_exit 143' TERM

###############################################################
# Función Interactiva mejorada
function select_target_interactively() {
    # Verificar dependencias
    if ! command -v jq &> /dev/null; then
        log_error "La herramienta 'jq' no está instalada, pero es necesaria para el modo interactivo."
        echo "Instalación:"
        echo "  Ubuntu/Debian: sudo apt-get install jq"
        echo "  macOS: brew install jq"
        echo "  CentOS/RHEL: sudo yum install jq"
        cleanup_and_exit 1
    fi

    header "Modo Interactivo - Entorno: $environment"
    log_info "Generando plan para identificar cambios disponibles..."
    
    # Generar plan silenciosamente
    if ! terraform -chdir="environments/$environment" plan $other_args -out="$PLAN_FILE" > /dev/null 2>&1; then
        log_error "Error al generar el plan de Terraform"
        cleanup_and_exit 1
    fi
    
    # Convertir a JSON
    if ! terraform -chdir="environments/$environment" show -json "$PLAN_FILE" > "$PLAN_JSON" 2>&1; then
        log_error "Error al convertir el plan a JSON"
        cleanup_and_exit 1
    fi

    # Extraer recursos con sus acciones
    mapfile -t available_targets < <(
        jq -r '.resource_changes[] | 
               select(.change.actions[] != "no-op") | 
               "\(.address) (\(.change.actions | join(",")))"' "$PLAN_JSON" 2>/dev/null
    )

    if [ ${#available_targets[@]} -eq 0 ]; then
        log_info "El plan no contiene cambios. Infraestructura actualizada."
        cleanup_and_exit 0
    fi

    echo ""
    echo "Recursos que serán modificados:"
    echo "================================="
    local i=1
    for target in "${available_targets[@]}"; do
        # Colorear según el tipo de acción
        local color=""
        local reset="\033[0m"
        if [[ "$target" == *"(create)"* ]]; then
            color="\033[32m"  # Verde
        elif [[ "$target" == *"(update)"* ]]; then
            color="\033[33m"  # Amarillo
        elif [[ "$target" == *"(delete)"* ]]; then
            color="\033[31m"  # Rojo
        fi
        
        printf "  ${color}%2d) %s${reset}\n" "$i" "$target"
        ((i++))
    done

    echo ""
    local selection
    while true; do
        read -p "Selecciona el recurso (1-${#available_targets[@]}, 'a' para todos, 'c' para cancelar): " selection
        
        if [[ "$selection" == "c" || "$selection" == "C" ]]; then
            log_info "Operación cancelada por el usuario"
            cleanup_and_exit 0
        elif [[ "$selection" == "a" || "$selection" == "A" ]]; then
            # Aplicar plan completo
            header "Aplicando plan completo"
            if terraform -chdir="environments/$environment" apply -auto-approve "$PLAN_FILE"; then
                footer
                cleanup_and_exit 0
            else
                log_error "Error durante la aplicación del plan"
                cleanup_and_exit 1
            fi
        elif [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#available_targets[@]} )); then
            break
        else
            log_warning "Selección inválida. Introduce un número válido, 'a' o 'c'."
        fi
    done

    # Extraer dirección del recurso
    local chosen_target_address
    chosen_target_address=$(echo "${available_targets[$((selection - 1))]}" | awk '{print $1}')
    
    # Mostrar plan específico
    header "Plan específico para: $chosen_target_address"
    terraform -chdir="environments/$environment" plan -target="$chosen_target_address" $other_args

    # Confirmar aplicación
    echo ""
    local confirm
    read -p "¿Aplicar estos cambios? (s/N): " confirm
    if [[ "$confirm" == "s" || "$confirm" == "S" || "$confirm" == "y" || "$confirm" == "Y" ]]; then
        header "Aplicando cambios para: $chosen_target_address"
        if terraform -chdir="environments/$environment" apply -target="$chosen_target_address" -auto-approve "$PLAN_FILE"; then
            footer
            cleanup_and_exit 0
        else
            log_error "Error durante la aplicación del plan específico"
            cleanup_and_exit 1
        fi
    else
        log_info "Aplicación cancelada. Archivos temporales eliminados."
        cleanup_and_exit 0
    fi
}

###############################################################
# Validaciones mejoradas
function validate_action() { 
    local valid_actions=("init" "plan" "apply" "build")
    if [[ ! " ${valid_actions[*]} " =~ " $1 " ]]; then
        log_error "Acción no reconocida: '$1'"
        echo "Acciones válidas: ${valid_actions[*]}"
        help
    fi
}

function validate_tf_environment() { 
    if [[ -z "$1" ]]; then
        log_error "El entorno es obligatorio"
        echo "Entornos disponibles en ./environments/:"
        find environments/ -maxdepth 1 -type d -not -path environments/ -exec basename {} \; 2>/dev/null | sort || echo "  (ninguno encontrado)"
        cleanup_and_exit 1
    fi
    
    if [[ ! -d "environments/$1/" ]]; then
        log_error "Entorno '$1' no encontrado en ./environments/"
        echo "Entornos disponibles:"
        find environments/ -maxdepth 1 -type d -not -path environments/ -exec basename {} \; 2>/dev/null | sort || echo "  (ninguno encontrado)"
        cleanup_and_exit 1
    fi
    
    # Establecer la variable global para limpieza
    CURRENT_ENV="$1"
}

function validate_tf_templates() { 
    shopt -s nullglob
    local files=(templates/*.tpl)
    if (( ${#files[@]} )); then
        log_info "Procesando ${#files[@]} templates..."
        dos2unix "${files[@]}" >/dev/null 2>&1
    fi
    shopt -u nullglob
}

function validate_dependencies() {
    local missing_deps=()
    
    if [[ "$1" == "terraform" ]]; then
        command -v terraform >/dev/null || missing_deps+=("terraform")
    elif [[ "$1" == "packer" ]]; then
        command -v packer >/dev/null || missing_deps+=("packer")
    fi
    
    if (( ${#missing_deps[@]} > 0 )); then
        log_error "Dependencias faltantes: ${missing_deps[*]}"
        echo "Consulta la documentación de instalación oficial."
        cleanup_and_exit 1
    fi
}

###############################################################
# Funciones principales mejoradas
function init() {
    validate_dependencies "terraform"
    validate_tf_environment "$environment"
    header "Terraform Init - Entorno: $environment"
    
    log_info "Inicializando backend y providers..."
    if terraform -chdir="environments/$environment" init $other_args; then
        footer
    else
        log_error "Error durante terraform init"
        cleanup_and_exit 1
    fi
}

function plan() {
    init
    
    # Modo interactivo
    if [[ "$interactive_mode" == "true" ]]; then
        select_target_interactively
        return
    fi
    
    # Plan normal
    header "Terraform Plan - Entorno: $environment"
    validate_tf_templates
    
    log_info "Generando plan de ejecución..."
    if terraform -chdir="environments/$environment" plan $target_arg $other_args; then
        footer
    else
        log_error "Error durante terraform plan"
        cleanup_and_exit 1
    fi
}

function apply() {
    init
    header "Terraform Apply - Entorno: $environment"
    validate_tf_templates
    
    log_info "Aplicando cambios de infraestructura..."
    if terraform -chdir="environments/$environment" apply $target_arg $other_args; then
        footer
    else
        log_error "Error durante terraform apply"
        cleanup_and_exit 1
    fi
}

function build() {
    validate_dependencies "packer"
    
    if [[ -z "$environment" ]]; then
        log_error "Debes especificar una aplicación para construir con Packer"
        echo "Ejemplo: ./make build webapp"
        cleanup_and_exit 1
    fi
    
    if [[ ! -f "$environment" ]]; then
        log_error "Archivo de template Packer '$environment' no encontrado"
        echo "Templates disponibles:"
        find . -name "*.pkr.hcl" -o -name "*.json" | grep -E "(packer|build)" || echo "  (ninguno encontrado)"
        cleanup_and_exit 1
    fi
    
    header "Packer Build - Aplicación: $environment"
    
    local build_args=""
    for arg in "${@:3}"; do 
        build_args+=" $arg"
    done
    
    log_info "Construyendo imagen con Packer..."
    if packer build $build_args "$environment"; then
        footer
    else
        log_error "Error durante packer build"
        cleanup_and_exit 1
    fi
}

###############################################################
# Procesamiento de argumentos mejorado
action="${1:-}"
environment="${2:-}"

target_arg=""
other_args=""
interactive_mode="false"

# Procesar argumentos adicionales
for arg in "${@:3}"; do
    if [[ "$arg" == "-target" ]]; then
        interactive_mode="true"
    elif [[ "$arg" == -target=* ]]; then
        target_arg="$arg"
    else
        other_args+=" \"$arg\""
    fi
done

###############################################################
# Ejecución principal
if [[ -z "$action" ]]; then
    help
fi

validate_action "$action"

# Ejecutar acción
"$action"