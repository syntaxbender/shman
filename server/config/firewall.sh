#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/common.sh
source "$REPO_ROOT/lib/common.sh"

# ==========================
# Interactive iptables setup
# ==========================

is_valid_interface() {
  local interface_name="$1"

  [[ "$interface_name" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] && \
    [[ -d "/sys/class/net/$interface_name" ]]
}

collect_default_route_interfaces() {
  local family="$1"
  local result_name="$2"
  local line
  local interface_name
  local candidate
  local found
  local index
  local words=()
  local -n result="$result_name"

  result=()
  while IFS= read -r line; do
    words=()
    read -ra words <<<"$line"

    for ((index = 0; index < ${#words[@]}; index += 1)); do
      if [[ "${words[$index]}" == dev && $((index + 1)) -lt ${#words[@]} ]]; then
        interface_name="${words[$((index + 1))]}"
        found=0
        for candidate in "${result[@]}"; do
          if [[ "$candidate" == "$interface_name" ]]; then
            found=1
            break
          fi
        done
        [[ "$found" -eq 1 ]] || result+=("$interface_name")
      fi
    done
  done < <(ip "-$family" route show default)
}

select_wan_interface() {
  local family_label="$1"
  local result_name="$2"
  local candidates_name="$3"
  local fallback="${4:-}"
  local answer
  local suggested=""
  local -n result="$result_name"
  local -n candidates="$candidates_name"

  if [[ "${#candidates[@]}" -gt 0 ]]; then
    suggested="${candidates[0]}"
    echo "$family_label default route arayüzleri: ${candidates[*]}"
  elif [[ -n "$fallback" ]]; then
    suggested="$fallback"
    echo "$family_label default route bulunamadı; önerilen arayüz: $suggested"
  else
    echo "$family_label default route bulunamadı."
  fi

  while true; do
    if [[ -n "$suggested" ]]; then
      read -rp "$family_label WAN interface [$suggested]: " answer
      answer="${answer:-$suggested}"
    else
      read -rp "$family_label WAN interface: " answer
    fi

    if is_valid_interface "$answer"; then
      result="$answer"
      return 0
    fi

    echo "Geçerli bir yerel ağ arayüzü gir."
  done
}

add_tcp_port() {
  local port="$1"
  local label="$2"

  TCP_PORTS+=("$port")
  echo "✓ TCP $port seçildi ($label)"
}

add_udp_port() {
  local port="$1"
  local label="$2"

  UDP_PORTS+=("$port")
  echo "✓ UDP $port seçildi ($label)"
}

detect_ssh_port() {
  local detected_port=""

  if command -v sshd >/dev/null 2>&1; then
    detected_port="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
  fi

  if [[ "$detected_port" =~ ^[0-9]{1,5}$ ]] && \
    ((10#$detected_port >= 1 && 10#$detected_port <= 65535)); then
    printf '%s\n' "$((10#$detected_port))"
  else
    printf '%s\n' 22
  fi
}

emit_ipv4_wan_rules() {
  local port

  printf '%s\n' \
    "-A INPUT -i $IPV4_WAN_INTERFACE -j $WAN_INPUT_CHAIN" \
    "-A $WAN_INPUT_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

  if [[ "$PING_ENABLED" -eq 1 ]]; then
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p icmp -j ACCEPT"
  fi

  for port in "${TCP_PORTS[@]}"; do
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p tcp --dport $port -m conntrack --ctstate NEW -j ACCEPT"
  done

  for port in "${UDP_PORTS[@]}"; do
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p udp --dport $port -m conntrack --ctstate NEW -j ACCEPT"
  done

  printf '%s\n' "-A $WAN_INPUT_CHAIN -j DROP"
}

emit_ipv6_wan_rules() {
  local icmpv6_type
  local port

  printf '%s\n' "-A INPUT -i $IPV6_WAN_INTERFACE -j $WAN_INPUT_CHAIN"

  if [[ "$IPV6_ENABLED" -eq 0 ]]; then
    printf '%s\n' "-A $WAN_INPUT_CHAIN -j DROP"
    return 0
  fi

  printf '%s\n' "-A $WAN_INPUT_CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

  # ICMPv6 yalnızca ping değildir. Bu tipler IPv6 hata bildirimi,
  # Path MTU Discovery, multicast ve Neighbor Discovery için gereklidir.
  for icmpv6_type in 1 2 3 4 130 131 132 133 134 135 136 143; do
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p ipv6-icmp --icmpv6-type $icmpv6_type -j ACCEPT"
  done

  if [[ "$PING_ENABLED" -eq 1 ]]; then
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p ipv6-icmp --icmpv6-type 128 -j ACCEPT"
  fi

  for port in "${TCP_PORTS[@]}"; do
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p tcp --dport $port -m conntrack --ctstate NEW -j ACCEPT"
  done

  for port in "${UDP_PORTS[@]}"; do
    printf '%s\n' "-A $WAN_INPUT_CHAIN -p udp --dport $port -m conntrack --ctstate NEW -j ACCEPT"
  done
  printf '%s\n' "-A $WAN_INPUT_CHAIN -j DROP"
}

build_filter_ruleset() {
  local family="$1"
  local save_command="$2"
  local destination="$3"
  local current_rules
  local line
  local wan_rules_emitted=0

  current_rules="$(mktemp /tmp/iptables-setup-current.XXXXXX)"
  TEMP_FILES+=("$current_rules")
  "$save_command" -t filter >"$current_rules"

  : >"$destination"
  while IFS= read -r line; do
    if [[ "$line" == ":$WAN_INPUT_CHAIN "* ]]; then
      continue
    elif [[ "$line" == :FORWARD\ * && "$RESET_FORWARD" -eq 1 ]]; then
      printf '%s\n' ':FORWARD DROP [0:0]' >>"$destination"
    elif [[ "$line" == :OUTPUT\ * && "$RESET_OUTPUT" -eq 1 ]]; then
      printf '%s\n' ':OUTPUT ACCEPT [0:0]' >>"$destination"
    elif [[ "$line" == "-A $WAN_INPUT_CHAIN "* ]]; then
      continue
    elif [[ "$line" == -A\ * && \
      ( "$line" == *" -j $WAN_INPUT_CHAIN"* || "$line" == *" -g $WAN_INPUT_CHAIN"* ) ]]; then
      continue
    elif [[ "$line" == -A\ FORWARD\ * && "$RESET_FORWARD" -eq 1 ]]; then
      continue
    elif [[ "$line" == -A\ OUTPUT\ * && "$RESET_OUTPUT" -eq 1 ]]; then
      continue
    elif [[ "$line" == -A\ * && "$wan_rules_emitted" -eq 0 ]]; then
      printf ':%s - [0:0]\n' "$WAN_INPUT_CHAIN" >>"$destination"
      if [[ "$family" == ipv4 ]]; then
        emit_ipv4_wan_rules >>"$destination"
      else
        emit_ipv6_wan_rules >>"$destination"
      fi
      wan_rules_emitted=1
      printf '%s\n' "$line" >>"$destination"
    elif [[ "$line" == COMMIT ]]; then
      if [[ "$wan_rules_emitted" -eq 0 ]]; then
        printf ':%s - [0:0]\n' "$WAN_INPUT_CHAIN" >>"$destination"
        if [[ "$family" == ipv4 ]]; then
          emit_ipv4_wan_rules >>"$destination"
        else
          emit_ipv6_wan_rules >>"$destination"
        fi
      fi
      printf '%s\n' COMMIT >>"$destination"
    else
      printf '%s\n' "$line" >>"$destination"
    fi
  done <"$current_rules"
}

set_ipv6_runtime_state() {
  local disabled="$1"
  local interface_sysctl="/proc/sys/net/ipv6/conf/$IPV6_WAN_INTERFACE/disable_ipv6"

  if [[ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    if [[ "$disabled" -eq 0 ]]; then
      echo "IPv6 bu kernel/önyükleme yapılandırmasında etkinleştirilemiyor." >&2
      exit 1
    fi

    return 0
  fi

  if [[ ! -e "$interface_sysctl" ]]; then
    echo "IPv6 sysctl arayüzü bulunamadı: $IPV6_WAN_INTERFACE" >&2
    return 1
  fi

  IPV6_RUNTIME_TOUCHED=1
  sysctl -q -w "net/ipv6/conf/$IPV6_WAN_INTERFACE/disable_ipv6=$disabled"

  if ! verify_ipv6_runtime_state "$disabled"; then
    if [[ "$disabled" -eq 0 ]]; then
      echo "IPv6 WAN arayüzünde etkinleştirilemedi: $IPV6_WAN_INTERFACE" >&2
    else
      echo "IPv6 WAN arayüzünde kapatılamadı: $IPV6_WAN_INTERFACE" >&2
    fi
    return 1
  fi
}

verify_ipv6_runtime_state() {
  local expected="$1"
  local path="/proc/sys/net/ipv6/conf/$IPV6_WAN_INTERFACE/disable_ipv6"
  local actual

  if [[ ! -e "$path" ]]; then
    echo "Doğrulanabilecek IPv6 WAN arayüzü bulunamadı: $IPV6_WAN_INTERFACE" >&2
    return 1
  fi

  actual="$(< "$path")"
  if [[ "$actual" -ne "$expected" ]]; then
    echo "IPv6 durum uyuşmazlığı: $IPV6_WAN_INTERFACE disable_ipv6=$actual (beklenen: $expected)" >&2
    return 1
  fi
}

check_external_ipv6_settings() {
  local expected_disabled="$1"
  local file
  local line
  local normalized_line
  local line_number
  local configured_scope
  local configured_value
  local conflict=0
  local kernel_arg
  local kernel_cmdline=""
  local kernel_args=()
  local config_pattern='^[[:space:]]*-?[[:space:]]*net\.ipv6\.conf\.([^=[:space:]]+)\.disable_ipv6[[:space:]]*=[[:space:]]*([01])[[:space:]]*$'
  local candidates=(
    /etc/sysctl.conf
    /etc/sysctl.d/*.conf
    /run/sysctl.d/*.conf
    /usr/local/lib/sysctl.d/*.conf
    /usr/lib/sysctl.d/*.conf
    /lib/sysctl.d/*.conf
  )

  IPV6_BOOT_DISABLED=0
  if [[ -r /proc/cmdline ]]; then
    kernel_cmdline="$(< /proc/cmdline)"
    read -ra kernel_args <<<"$kernel_cmdline"
    for kernel_arg in "${kernel_args[@]}"; do
      if [[ "$kernel_arg" == ipv6.disable=1 ]]; then
        IPV6_BOOT_DISABLED=1
        if [[ "$expected_disabled" -eq 0 ]]; then
          echo "Çakışma: kernel komut satırında ipv6.disable=1 bulunuyor." >&2
          return 1
        fi
      fi
    done
  fi

  for file in "${candidates[@]}"; do
    [[ -f "$file" ]] || continue
    [[ "$file" == /etc/sysctl.d/99-disable-ipv6.conf ]] && continue

    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      ((line_number += 1))
      line="${line%%#*}"
      line="${line%%;*}"
      normalized_line="${line//\//.}"

      if [[ "$normalized_line" =~ $config_pattern ]]; then
        configured_scope="${BASH_REMATCH[1]}"
        configured_value="${BASH_REMATCH[2]}"

        # Docker/VPN/bridge gibi diğer arayüzlerin ayarları bu scriptin
        # kapsamı değildir. Yalnız global veya seçili WAN ayarı çakışabilir.
        if [[ "$configured_scope" != all && "$configured_scope" != "$IPV6_WAN_INTERFACE" ]]; then
          continue
        fi

        if [[ "$configured_value" -ne "$expected_disabled" ]]; then
          echo "Harici IPv6 sysctl çakışması: $file:$line_number" >&2
          echo "  $line" >&2
          conflict=1
        fi
      fi
    done <"$file"
  done

  if [[ "$conflict" -eq 1 ]]; then
    if [[ "$PERSIST_RULES" -eq 1 ]]; then
      echo "Harici sysctl ayarı otomatik değiştirilmedi; WAN IPv6 durumunun kalıcılığı garanti edilemiyor." >&2
      return 1
    fi

    echo "Uyarı: Harici sysctl ayarı yeniden başlatmada farklı bir IPv6 durumu uygulayabilir." >&2
  fi
}

write_ipv6_disable_config() {
  local temp_config

  temp_config="$(mktemp /etc/sysctl.d/.99-disable-ipv6.conf.XXXXXX)"
  TEMP_FILES+=("$temp_config")

  printf '%s\n' \
    "net/ipv6/conf/$IPV6_WAN_INTERFACE/disable_ipv6 = 1" >"$temp_config"

  chmod 0644 "$temp_config"
  mv -f "$temp_config" /etc/sysctl.d/99-disable-ipv6.conf
}

show_chain() {
  local command_name="$1"
  local family_label="$2"
  local chain="$3"

  echo
  echo "$family_label $chain kuralları:"
  "$command_name" --wait "$XTABLES_WAIT_SECONDS" -L "$chain" -n -v --line-numbers
}

persistence_packages_installed() {
  local package
  local package_status

  command -v dpkg-query >/dev/null 2>&1 || return 1

  for package in iptables-persistent netfilter-persistent; do
    package_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" || return 1
    [[ "$package_status" == "install ok installed" ]] || return 1
  done
}

capture_transaction_state() {
  local path

  ORIGINAL_V4_RULESET="$(mktemp /tmp/iptables-setup-original-v4.XXXXXX)"
  TEMP_FILES+=("$ORIGINAL_V4_RULESET")
  iptables-save >"$ORIGINAL_V4_RULESET"

  if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    ORIGINAL_V6_RULESET="$(mktemp /tmp/iptables-setup-original-v6.XXXXXX)"
    TEMP_FILES+=("$ORIGINAL_V6_RULESET")
    ip6tables-save >"$ORIGINAL_V6_RULESET"
  fi

  IPV6_ORIGINAL_PATHS=()
  IPV6_ORIGINAL_VALUES=()
  path="/proc/sys/net/ipv6/conf/$IPV6_WAN_INTERFACE/disable_ipv6"
  if [[ -e "$path" ]]; then
    IPV6_ORIGINAL_PATHS+=("$path")
    IPV6_ORIGINAL_VALUES+=("$(< "$path")")
  fi

  if [[ -e /etc/sysctl.d/99-disable-ipv6.conf ]]; then
    SYSCTL_CONFIG_EXISTED=1
    SYSCTL_CONFIG_BACKUP="$(mktemp /tmp/iptables-setup-sysctl.XXXXXX)"
    TEMP_FILES+=("$SYSCTL_CONFIG_BACKUP")
    cp -p -- /etc/sysctl.d/99-disable-ipv6.conf "$SYSCTL_CONFIG_BACKUP"
  fi

  if [[ -e /etc/iptables/rules.v4 ]]; then
    RULES_V4_EXISTED=1
    RULES_V4_BACKUP="$(mktemp /tmp/iptables-setup-rules-v4.XXXXXX)"
    TEMP_FILES+=("$RULES_V4_BACKUP")
    cp -p -- /etc/iptables/rules.v4 "$RULES_V4_BACKUP"
  fi

  if [[ -e /etc/iptables/rules.v6 ]]; then
    RULES_V6_EXISTED=1
    RULES_V6_BACKUP="$(mktemp /tmp/iptables-setup-rules-v6.XXXXXX)"
    TEMP_FILES+=("$RULES_V6_BACKUP")
    cp -p -- /etc/iptables/rules.v6 "$RULES_V6_BACKUP"
  fi

  if command -v ufw >/dev/null 2>&1; then
    UFW_PRESENT=1
    if ! UFW_STATUS_OUTPUT="$(LC_ALL=C ufw status 2>&1)"; then
      echo "UFW durumu okunamadı:" >&2
      echo "$UFW_STATUS_OUTPUT" >&2
      return 1
    fi

    case "$UFW_STATUS_OUTPUT" in
      *"Status: active"*) UFW_WAS_ACTIVE=1 ;;
      *"Status: inactive"*) UFW_WAS_ACTIVE=0 ;;
      *)
        echo "UFW durumu anlaşılamadı:" >&2
        echo "$UFW_STATUS_OUTPUT" >&2
        return 1
        ;;
    esac
  fi
}

stage_persistent_rules() {
  mkdir -p /etc/iptables

  PERSIST_V4_STAGE="$(mktemp /etc/iptables/.rules.v4.new.XXXXXX)"
  TEMP_FILES+=("$PERSIST_V4_STAGE")
  iptables-save >"$PERSIST_V4_STAGE"
  chmod 0600 "$PERSIST_V4_STAGE"
  iptables-restore --wait "$XTABLES_WAIT_SECONDS" --test <"$PERSIST_V4_STAGE"

  if [[ -n "$V6_RULESET" ]]; then
    PERSIST_V6_STAGE="$(mktemp /etc/iptables/.rules.v6.new.XXXXXX)"
    TEMP_FILES+=("$PERSIST_V6_STAGE")
    ip6tables-save >"$PERSIST_V6_STAGE"
    chmod 0600 "$PERSIST_V6_STAGE"
    ip6tables-restore --wait "$XTABLES_WAIT_SECONDS" --test <"$PERSIST_V6_STAGE"
  fi
}

restore_managed_files() {
  if [[ "$SYSCTL_CONFIG_TOUCHED" -eq 1 ]]; then
    if [[ "$SYSCTL_CONFIG_EXISTED" -eq 1 ]]; then
      cp -p -- "$SYSCTL_CONFIG_BACKUP" /etc/sysctl.d/99-disable-ipv6.conf
    else
      rm -f -- /etc/sysctl.d/99-disable-ipv6.conf
    fi
  fi

  if [[ "$PERSISTENCE_FILES_TOUCHED" -eq 1 ]]; then
    mkdir -p /etc/iptables

    if [[ "$RULES_V4_EXISTED" -eq 1 ]]; then
      cp -p -- "$RULES_V4_BACKUP" /etc/iptables/rules.v4
    else
      rm -f -- /etc/iptables/rules.v4
    fi

    if [[ "$RULES_V6_EXISTED" -eq 1 ]]; then
      cp -p -- "$RULES_V6_BACKUP" /etc/iptables/rules.v6
    else
      rm -f -- /etc/iptables/rules.v6
    fi
  fi
}

restore_ipv6_runtime_state() {
  local index
  local path
  local value

  [[ "$IPV6_RUNTIME_TOUCHED" -eq 1 ]] || return 0

  for index in "${!IPV6_ORIGINAL_PATHS[@]}"; do
    path="${IPV6_ORIGINAL_PATHS[$index]}"
    value="${IPV6_ORIGINAL_VALUES[$index]}"
    [[ -e "$path" ]] || continue

    if ! printf '%s\n' "$value" >"$path"; then
      echo "Rollback sırasında IPv6 durumu geri yüklenemedi: $path" >&2
    fi
  done
}

rollback_transaction() {
  echo >&2
  echo "Hata/kesinti algılandı; önceki firewall durumu geri yükleniyor..." >&2
  set +e

  restore_managed_files
  restore_ipv6_runtime_state

  if [[ "$NETFILTER_ENABLE_TOUCHED" -eq 1 ]]; then
    if [[ "$NETFILTER_WAS_ENABLED" -eq 1 ]]; then
      systemctl enable netfilter-persistent >/dev/null 2>&1
    else
      systemctl disable --now netfilter-persistent >/dev/null 2>&1
    fi
  fi

  if [[ "$UFW_PRESENT" -eq 1 && "$UFW_WAS_ACTIVE" -eq 1 ]]; then
    ufw --force enable >/dev/null 2>&1
  fi

  if [[ -n "$ORIGINAL_V4_RULESET" ]]; then
    iptables-restore --wait "$XTABLES_WAIT_SECONDS" <"$ORIGINAL_V4_RULESET" || \
      echo "Uyarı: Önceki IPv4 kuralları geri yüklenemedi." >&2
  fi

  if [[ -n "$ORIGINAL_V6_RULESET" ]]; then
    ip6tables-restore --wait "$XTABLES_WAIT_SECONDS" <"$ORIGINAL_V6_RULESET" || \
      echo "Uyarı: Önceki IPv6 kuralları geri yüklenemedi." >&2
  fi

  echo "Rollback tamamlandı." >&2
}

TEMP_FILES=()
TCP_PORTS=()
UDP_PORTS=()
IPV4_WAN_CANDIDATES=()
IPV6_WAN_CANDIDATES=()
IPV6_ORIGINAL_PATHS=()
IPV6_ORIGINAL_VALUES=()
XTABLES_WAIT_SECONDS=10
WAN_INPUT_CHAIN="SHMAN_WAN_IN"
IPV4_WAN_INTERFACE=""
IPV6_WAN_INTERFACE=""
PING_ENABLED=0
IPV6_ENABLED=1
RESET_FORWARD=0
RESET_OUTPUT=0
PERSIST_RULES=1
FWKNOP_PORT=""
SSH_PORT=""
SSH_PORT_DEFAULT=22
IPV6_BOOT_DISABLED=0
IPV6_RUNTIME_TOUCHED=0
UFW_PRESENT=0
UFW_WAS_ACTIVE=0
UFW_STATUS_OUTPUT=""
ORIGINAL_V4_RULESET=""
ORIGINAL_V6_RULESET=""
SYSCTL_CONFIG_EXISTED=0
SYSCTL_CONFIG_TOUCHED=0
SYSCTL_CONFIG_BACKUP=""
RULES_V4_EXISTED=0
RULES_V6_EXISTED=0
RULES_V4_BACKUP=""
RULES_V6_BACKUP=""
PERSISTENCE_FILES_TOUCHED=0
NETFILTER_WAS_ENABLED=0
NETFILTER_ENABLE_TOUCHED=0
PERSIST_V4_STAGE=""
PERSIST_V6_STAGE=""
TRANSACTION_ACTIVE=0
DESIRED_IPV6_DISABLED=0
V4_RULESET=""
V6_RULESET=""

cleanup() {
  local path

  for path in "${TEMP_FILES[@]}"; do
    [[ -n "$path" ]] && rm -f -- "$path"
  done
}

on_exit() {
  local status=$?

  trap - EXIT INT TERM
  set +e

  if [[ "$status" -ne 0 && "$TRANSACTION_ACTIVE" -eq 1 ]]; then
    rollback_transaction
  fi

  cleanup
  exit "$status"
}

on_interrupt() {
  local signal_name="$1"

  echo >&2
  echo "$signal_name sinyali alındı." >&2
  if [[ "$signal_name" == INT ]]; then
    exit 130
  fi
  exit 143
}

print_banner() {
echo "========================================="
echo "   Interactive iptables setup"
echo "========================================="
echo
echo "Default profile:"
echo
echo "AÇIK:"
echo "  - SSH            (port çalışma sırasında sorulur)"
echo "  - HTTP           (80)"
echo "  - HTTPS          (443)"
echo "  - SMTP inbound   (25)"
echo "  - SMTP submit    (587)"
echo "  - IMAPS          (993)"
echo
echo "KAPALI:"
echo "  - SMTPS legacy   (465)"
echo "  - IMAP plain     (143)"
echo "  - POP3           (110)"
echo "  - POP3S          (995)"
echo "  - ICMP/Ping"
echo "  - IPv6'yı kapatma"
echo
echo "WAN giriş trafiği özel bir zincirle filtrelenecek."
echo "Diğer INPUT arayüzleri korunacak; FORWARD ve OUTPUT için ayrıca onay alınacak."
echo
}

confirm_execution() {
if ! ask_default_yes "Devam edilsin mi?"; then
  echo "İptal edildi."
  exit 0
fi
}

require_initial_dependencies() {
# Salt okunur gösterim için gereken IPv4 araçlarını önce doğrula.
require_command_or_install iptables "sudo ./server/install.sh --firewall"
require_command_or_install iptables-save "sudo ./server/install.sh --firewall"
require_command_or_install iptables-restore "sudo ./server/install.sh --firewall"
require_command_or_install ip "sudo ./server/install.sh --firewall"
require_command awk
}

collect_wan_settings() {
collect_default_route_interfaces 4 IPV4_WAN_CANDIDATES
collect_default_route_interfaces 6 IPV6_WAN_CANDIDATES

echo
echo "=== WAN INTERFACE ==="
echo "IPv4 default route:"
ip -4 route show default || true
echo "IPv6 default route:"
ip -6 route show default || true
echo

select_wan_interface IPv4 IPV4_WAN_INTERFACE IPV4_WAN_CANDIDATES

echo
if ask_default_no "IPv6 WAN arayüzünde kapatılsın mı?"; then
  IPV6_ENABLED=0
fi

select_wan_interface IPv6 IPV6_WAN_INTERFACE IPV6_WAN_CANDIDATES "$IPV4_WAN_INTERFACE"

echo
echo "Seçilen IPv4 WAN interface: $IPV4_WAN_INTERFACE"
echo "Seçilen IPv6 WAN interface: $IPV6_WAN_INTERFACE"
}

collect_chain_reset_preferences() {
echo
echo "=== MEVCUT FORWARD / OUTPUT ==="
show_chain iptables IPv4 FORWARD
show_chain iptables IPv4 OUTPUT

if command -v ip6tables >/dev/null 2>&1; then
  if ! show_chain ip6tables IPv6 FORWARD; then
    echo "IPv6 FORWARD kuralları okunamadı."
  fi
  if ! show_chain ip6tables IPv6 OUTPUT; then
    echo "IPv6 OUTPUT kuralları okunamadı."
  fi
else
  echo
  echo "ip6tables bulunamadığı için mevcut IPv6 kuralları gösterilemedi."
fi

echo
if ask_default_no "IPv4 ve IPv6 FORWARD kuralları sıfırlansın mı?"; then
  RESET_FORWARD=1
fi

if ask_default_no "IPv4 ve IPv6 OUTPUT kuralları sıfırlansın mı?"; then
  RESET_OUTPUT=1
fi
}

collect_service_preferences() {
echo
echo "=== ICMP ==="
if ask_default_no "Ping açık olsun mu?"; then
  PING_ENABLED=1
fi

echo
echo "=== SSH ==="
if ask_default_yes "SSH portu WAN'da açılsın mı?"; then
  SSH_PORT_DEFAULT="$(detect_ssh_port)"
  read_port "SSH TCP portu" "$SSH_PORT_DEFAULT" SSH_PORT
  add_tcp_port "$SSH_PORT" "SSH"
fi

echo
echo "=== WEB ==="
if ask_default_yes "HTTP/HTTPS açılsın mı? (80,443)"; then
  add_tcp_port 80 "HTTP"
  add_tcp_port 443 "HTTPS"
fi

echo
echo "=== MAIL SMTP ==="
if ask_default_yes "SMTP inbound açılsın mı? (25)"; then
  add_tcp_port 25 "SMTP inbound"
fi

if ask_default_yes "SMTP submission açılsın mı? (587 STARTTLS)"; then
  add_tcp_port 587 "SMTP submission"
fi

if ask_default_no "Legacy SMTPS açılsın mı? (465)"; then
  add_tcp_port 465 "SMTPS legacy"
fi

echo
echo "=== MAIL IMAP ==="
if ask_default_yes "IMAPS açılsın mı? (993 SSL/TLS)"; then
  add_tcp_port 993 "IMAPS"
fi

if ask_default_no "Plain IMAP açılsın mı? (143 STARTTLS)"; then
  add_tcp_port 143 "IMAP STARTTLS"
fi

echo
echo "=== MAIL POP3 ==="
if ask_default_no "POP3 açılsın mı? (110)"; then
  add_tcp_port 110 "POP3"
fi

if ask_default_no "POP3S açılsın mı? (995)"; then
  add_tcp_port 995 "POP3S"
fi

echo
echo "=== FWKNOP ==="
if ask_default_no "fwknop UDP portu eklensin mi?"; then
  while true; do
    read -rp "fwknop UDP port: " FWKNOP_PORT
    if [[ "$FWKNOP_PORT" =~ ^[0-9]{1,5}$ ]] && \
      (( 10#$FWKNOP_PORT >= 1 && 10#$FWKNOP_PORT <= 65535 )); then
      FWKNOP_PORT="$((10#$FWKNOP_PORT))"
      break
    fi
    echo "Geçerli bir port gir (1-65535)."
  done
  add_udp_port "$FWKNOP_PORT" "fwknop"
fi
}

collect_persistence_preference() {
echo
if ask_default_yes "IPv4 ve IPv6 durumu yeniden başlatmalarda kalıcı olsun mu?"; then
  PERSIST_RULES=1
else
  PERSIST_RULES=0
  echo "Uyarı: Eski rules.v4/rules.v6 silinecek; bu ayarlar yalnızca mevcut oturumda geçerli olacak."
fi
}

run_preflight_checks() {
# Bütün sorular yanıtlandı. Bundan sonra ön kontrol ve uygulama yapılır.
require_commands sysctl mktemp chmod mv rm mkdir cp

DESIRED_IPV6_DISABLED=0
if [[ "$IPV6_ENABLED" -eq 0 ]]; then
  DESIRED_IPV6_DISABLED=1
fi

if ! check_external_ipv6_settings "$DESIRED_IPV6_DISABLED"; then
  exit 1
fi

if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
  require_command_or_install ip6tables "sudo ./server/install.sh --firewall"
  require_command_or_install ip6tables-save "sudo ./server/install.sh --firewall"
  require_command_or_install ip6tables-restore "sudo ./server/install.sh --firewall"

  if [[ ! -e "/proc/sys/net/ipv6/conf/$IPV6_WAN_INTERFACE/disable_ipv6" ]]; then
    echo "Seçilen WAN arayüzünün IPv6 sysctl kaydı bulunamadı: $IPV6_WAN_INTERFACE" >&2
    exit 1
  fi
elif [[ "$IPV6_ENABLED" -eq 1 ]]; then
  echo "IPv6 kernel/önyükleme seviyesinde kapalı; bu scriptle etkinleştirilemiyor." >&2
  exit 1
fi

if [[ "$PERSIST_RULES" -eq 1 ]]; then
  require_command systemctl

  if ! persistence_packages_installed; then
    echo "Kalıcılık paketleri kurulu değil." >&2
    echo "Önce çalıştır: sudo ./server/install.sh --firewall" >&2
    exit 1
  fi

  if systemctl is-enabled --quiet netfilter-persistent; then
    NETFILTER_WAS_ENABLED=1
  fi
fi
}

prepare_rulesets() {
V4_RULESET="$(mktemp /tmp/iptables-setup-v4.XXXXXX)"
TEMP_FILES+=("$V4_RULESET")
build_filter_ruleset ipv4 iptables-save "$V4_RULESET"
iptables-restore --wait "$XTABLES_WAIT_SECONDS" --test <"$V4_RULESET"

V6_RULESET=""
if [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
  V6_RULESET="$(mktemp /tmp/iptables-setup-v6.XXXXXX)"
  TEMP_FILES+=("$V6_RULESET")
  build_filter_ruleset ipv6 ip6tables-save "$V6_RULESET"
  ip6tables-restore --wait "$XTABLES_WAIT_SECONDS" --test <"$V6_RULESET"
fi
}

apply_firewall_configuration() {
capture_transaction_state
TRANSACTION_ACTIVE=1

echo
echo "Firewall kuralları uygulanıyor..."
if [[ "$UFW_PRESENT" -eq 1 && "$UFW_WAS_ACTIVE" -eq 1 ]]; then
  echo "UFW disable ediliyor..."
  if ! ufw --force disable; then
    echo "UFW kapatılamadı; işlem geri alınacak." >&2
    exit 1
  fi
elif [[ "$UFW_PRESENT" -eq 1 ]]; then
  echo "UFW zaten kapalı."
fi

# Sorular artık tamamlandığı için ACCEPT politikasıyla uzun bir açık pencere oluşmaz.
iptables-restore --wait "$XTABLES_WAIT_SECONDS" <"$V4_RULESET"

if [[ -n "$V6_RULESET" ]]; then
  ip6tables-restore --wait "$XTABLES_WAIT_SECONDS" <"$V6_RULESET"
fi

SYSCTL_CONFIG_TOUCHED=1
if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  set_ipv6_runtime_state 0
  rm -f -- /etc/sysctl.d/99-disable-ipv6.conf
  echo "✓ IPv6 WAN arayüzünde etkin: $IPV6_WAN_INTERFACE"
else
  set_ipv6_runtime_state 1
  if [[ "$PERSIST_RULES" -eq 1 ]]; then
    write_ipv6_disable_config
    if [[ "$IPV6_BOOT_DISABLED" -eq 1 ]]; then
      echo "✓ IPv6 kernel boot parametresiyle sistem genelinde kapalı; WAN sysctl ayarı da kaydedildi"
    else
      echo "✓ IPv6 WAN arayüzünde kalıcı olarak kapatıldı: $IPV6_WAN_INTERFACE"
    fi
  else
    rm -f -- /etc/sysctl.d/99-disable-ipv6.conf
    if [[ "$IPV6_BOOT_DISABLED" -eq 1 || ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
      echo "✓ IPv6 kernel/önyükleme seviyesinde sistem genelinde zaten kapalı; harici kalıcı ayar değiştirilmedi"
    else
      echo "✓ IPv6 WAN arayüzünde yalnızca mevcut oturum için kapatıldı: $IPV6_WAN_INTERFACE"
    fi
  fi
fi

if [[ "$PERSIST_RULES" -eq 1 ]]; then
  # Her iki aile de başarıyla hazırlanmadıkça kalıcı dosyalara dokunma.
  stage_persistent_rules

  PERSISTENCE_FILES_TOUCHED=1
  mv -f -- "$PERSIST_V4_STAGE" /etc/iptables/rules.v4

  if [[ -n "$V6_RULESET" ]]; then
    mv -f -- "$PERSIST_V6_STAGE" /etc/iptables/rules.v6
  else
    rm -f -- /etc/iptables/rules.v6
  fi

  NETFILTER_ENABLE_TOUCHED=1
  systemctl enable netfilter-persistent
  echo "✓ Kalıcı durum kaydedildi"
else
  PERSISTENCE_FILES_TOUCHED=1
  rm -f -- /etc/iptables/rules.v4 /etc/iptables/rules.v6
  echo "✓ Eski kalıcı IPv4/IPv6 kural dosyaları silindi"
fi
}

print_final_status() {
echo
echo "Final IPv4 rules:"
iptables --wait "$XTABLES_WAIT_SECONDS" -L INPUT -n -v --line-numbers
iptables --wait "$XTABLES_WAIT_SECONDS" -L "$WAN_INPUT_CHAIN" -n -v --line-numbers
iptables --wait "$XTABLES_WAIT_SECONDS" -L FORWARD -n -v --line-numbers
iptables --wait "$XTABLES_WAIT_SECONDS" -L OUTPUT -n -v --line-numbers

if [[ -n "$V6_RULESET" ]]; then
  echo
  echo "Final IPv6 rules:"
  ip6tables --wait "$XTABLES_WAIT_SECONDS" -L INPUT -n -v --line-numbers
  ip6tables --wait "$XTABLES_WAIT_SECONDS" -L "$WAN_INPUT_CHAIN" -n -v --line-numbers
  ip6tables --wait "$XTABLES_WAIT_SECONDS" -L FORWARD -n -v --line-numbers
  ip6tables --wait "$XTABLES_WAIT_SECONDS" -L OUTPUT -n -v --line-numbers
else
  echo
  echo "IPv6 firewall tablosu kullanılamıyor (kernel/önyükleme seviyesinde kapalı)."
fi

if [[ "$IPV6_ENABLED" -eq 1 ]]; then
  echo "IPv6 WAN durumu: etkin ($IPV6_WAN_INTERFACE)"
elif [[ "$IPV6_BOOT_DISABLED" -eq 1 || ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
  echo "IPv6 durumu: sistem genelinde kernel/önyükleme seviyesinde kapalı"
else
  echo "IPv6 WAN durumu: kapalı ($IPV6_WAN_INTERFACE)"
fi
}

main() {
  require_root

  trap on_exit EXIT
  trap 'on_interrupt INT' INT
  trap 'on_interrupt TERM' TERM

  print_banner
  confirm_execution
  require_initial_dependencies
  collect_wan_settings
  collect_chain_reset_preferences
  collect_service_preferences
  collect_persistence_preference
  run_preflight_checks
  prepare_rulesets
  apply_firewall_configuration
  print_final_status

  TRANSACTION_ACTIVE=0

  echo
  echo "Tamamlandı."
}

main "$@"
