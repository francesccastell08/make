#!/bin/bash

set -euo pipefail

###############################################################
# Default stages
function help() {
    cat <<EOF
TERRAFORM COMMANDS:

	General
		./make <init|plan|apply> <environment> [flags]

	Targets
		./make plan pre -target=module.alb.aws_lb.main
		./make plan pre -target


PACKER COMMANDS:
	./make build <app> [flags]

		./make build webapp
		./make build api -var="ami_name=custom-api-v2"


NOTeS:
	- Available environments: pre, pro
	- Interactive mode (-target without a value) requires jq to be installed
	- .tpl files in the templates/ directory are processed automatically

EOF
	exit 1
}

###############################################################
# Funciones auxiliares mejoradas
function header() {
    echo ""
    echo ""
    echo "========================================================="
    echo "#"
    echo "# $1"
    echo "#"
    echo "========================================================="
}

function footer() {
	echo ""
	echo ""
    echo "========================================================="
    echo "#"
    echo "# Step completed"
    echo "#"
    echo "========================================================="
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
    if [[ -n "$CURRENT_ENV" && -d "$CURRENT_ENV" ]]; then
        [[ -f "$CURRENT_ENV/$PLAN_FILE" ]] && files_to_clean+=("$CURRENT_ENV/$PLAN_FILE")
        [[ -f "$CURRENT_ENV/$PLAN_JSON" ]] && files_to_clean+=("$CURRENT_ENV/$PLAN_JSON")
    fi

    # Limpiar archivos encontrados
    if (( ${#files_to_clean[@]} > 0 )); then
        log_info "Cleaning temporary files: ${files_to_clean[*]}"
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
trap 'log_warning "Script interrupted by the user"; cleanup_and_exit 130' INT
trap 'log_error "Script terminated unexpectedly"; cleanup_and_exit 143' TERM

###############################################################
# Función Interactiva mejorada
function select_target_interactively() {
    # Verificar dependencias
    if ! command -v jq &> /dev/null; then
        log_error "The 'jq' tool is not installed, but it is required for interactive mode"
        echo "Installing:"
        echo "  Ubuntu/Debian: sudo apt-get install jq"
        echo "  macOS: brew install jq"
        echo "  CentOS/RHEL: sudo yum install jq"
        cleanup_and_exit 1
    fi

    header "Interactive Mode - Environment: $environment"
    log_info "Generating plan to identify available changes..."

    # Generar plan silenciosamente
    if ! terraform -chdir="$environment" plan $other_args -out="$PLAN_FILE" > /dev/null 2>&1; then
        log_error "Error during terraform plan"
        cleanup_and_exit 1
    fi

    # Convertir a JSON
    if ! terraform -chdir="$environment" show -json "$PLAN_FILE" > "$PLAN_JSON" 2>&1; then
        log_error "Error converting the plan to JSON"
        cleanup_and_exit 1
    fi

    # Extraer recursos con sus acciones
    mapfile -t available_targets < <(
        jq -r '.resource_changes[] |
               select(.change.actions[] != "no-op") |
               "\(.address) (\(.change.actions | join(",")))"' "$PLAN_JSON" 2>/dev/null
    )

    if [ ${#available_targets[@]} -eq 0 ]; then
        log_info "This plan not contain any changes. Infraestructure is up to date."
        cleanup_and_exit 0
    fi

    echo ""
    echo "Resources that will be modified"
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
        read -p "Choose Resource (1-${#available_targets[@]}, 'a' for all, 'c' to Cancel): " selection

        if [[ "$selection" == "c" || "$selection" == "C" ]]; then
            log_info "Operacion has been cancelled by the user."
            cleanup_and_exit 0
        elif [[ "$selection" == "a" || "$selection" == "A" ]]; then
            # Aplicar plan completo
            header "Applying full plan"
            if terraform -chdir="$environment" apply -auto-approve "$PLAN_FILE"; then
                footer
                cleanup_and_exit 0
            else
                log_error "Error has been detected during plan application"
                cleanup_and_exit 1
            fi
        elif [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#available_targets[@]} )); then
            break
        else
            log_warning "Invalid selection. Choos a valid letter, 'a' o 'c'"
        fi
    done

    # Extraer dirección del recurso
    local chosen_target_address
    chosen_target_address=$(echo "${available_targets[$((selection - 1))]}" | awk '{print $1}')

    # Mostrar plan específico
    header "Plan específico para: $chosen_target_address"
    terraform -chdir="$environment" plan -target="$chosen_target_address" $other_args

    # Confirmar aplicación
    echo ""
    local confirm
    read -p "Do you want to apply these changes? (s/N): " confirm
    if [[ "$confirm" == "s" || "$confirm" == "S" || "$confirm" == "y" || "$confirm" == "Y" ]]; then
        header "Appling changes: $chosen_target_address"
        if terraform -chdir="$environment" apply -target="$chosen_target_address" -auto-approve "$PLAN_FILE"; then
            footer
            cleanup_and_exit 0
        else
            log_error "Error has been detected while applying the specific plan"
            cleanup_and_exit 1
        fi
    else
        log_info "This plan has been cancelled. Temporary files have been removed."
        cleanup_and_exit 0
    fi
}

###############################################################
# Validaciones mejoradas
function validate_action() {
    local valid_actions=("init" "plan" "apply" "build")
    if [[ ! " ${valid_actions[*]} " =~ " $1 " ]]; then
        log_error "This option doesn't exist: '$1'"
        echo "Valid options: ${valid_actions[*]}"
        help
	fi
}

function validate_tf_environment() {
    if [[ -z "$1" ]]; then
        log_error "The environment must be specified"
        echo "Environments availables:"
        find ./ -maxdepth 1 -type d -not -path ./ -exec basename {} \; 2>/dev/null | sort || echo "  (Not founded)"
        cleanup_and_exit 1
	fi

    if [[ ! -d "$1/" ]]; then
        log_error "Environment '$1' not founded"
        echo "Environments availables:"
        find ./ -maxdepth 1 -type d -not -path ./ -exec basename {} \; 2>/dev/null | sort || echo "  (Not founded)"
        cleanup_and_exit 1
	fi

    # Establecer la variable global para limpieza
    CURRENT_ENV="$1"
}

function validate_tf_templates() {
    shopt -s nullglob
    local files=(templates/*.tpl)
    if (( ${#files[@]} )); then
        log_info "Processing ${#files[@]} templates..."
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
        log_error "Missing dependencies: ${missing_deps[*]}"
        echo "You need to chec the official installation documentation."
        cleanup_and_exit 1
	fi
}

###############################################################
# Funciones principales mejoradas
function init() {
    validate_dependencies "terraform"
    validate_tf_environment "$environment"
    header "Terraform Init - Environment: $environment"

    log_info "Starting backend and Providers..."
    if terraform -chdir="$environment" init $other_args; then
	footer
    else
        log_error "Error has ocurred during terraform init"
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
    header "Terraform Plan - Environment: $environment"
    validate_tf_templates

    log_info "Generating plan to identify changes..."
    if terraform -chdir="$environment" plan $target_arg $other_args; then
	footer
    else
        log_error "Error has ocurred during terraform plan"
        cleanup_and_exit 1
    fi
}

function apply() {
	init
    header "Terraform Apply - Environment: $environment"
    validate_tf_templates

    log_info "Aplying changes to infrastructure..."
    if terraform -chdir="$environment" apply $target_arg $other_args; then
	footer
    else
        log_error "Error has ocurred during terraform plan"
        cleanup_and_exit 1
    fi
}

function build() {
    validate_dependencies "packer"

    if [[ -z "$environment" ]]; then
        log_error "You must to specify an application to build with Packer"
        echo "Ejemplo: ./make build webapp"
        cleanup_and_exit 1
    fi

    if [[ ! -d "./amis/$environment" ]]; then
        log_error "Packer template file '$environment' not found"
        echo "Templates availables:"
		find ./amis -maxdepth 1 -type d -not -path ./ -exec basename {} \; 2>/dev/null | sort || echo "  (not founded)"
        cleanup_and_exit 1
    fi

    header "Packer Build - App: $environment"

    local build_args=""
    for arg in "${@:3}"; do
        build_args+=" $arg"
    done

    log_info "Building image with Packer..."

	pushd "amis/$environment/"

	packer init "$environment.pkr.hcl"

    if packer build $build_args .; then
        popd > /dev/null
		footer
    else
        popd > /dev/null
        log_error "Error has ocurred during packer build"
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
