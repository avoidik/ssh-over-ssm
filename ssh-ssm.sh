#!/usr/bin/env bash

set -o nounset -o pipefail -o errexit

SSH_DIR="${HOME}/.ssh"

cleanup () {
  rm -f "${SSH_DIR}/ssm-ssh-tmp{,.pub}"
}

die () {
  echo "[${0##*/}] $*" >&2 > /dev/tty
  exit 1
}

main () {
  local ssh_pubkey ssm_cmd ssh_authkeys='.ssh/authorized_keys'

  if ! ssh_pubkey="$(ssh-add -L 2> /dev/null | head -1)" ; then
    if [[ ! -f "${SSH_DIR}/ssm-ssh-tmp.pub" ]]; then
      ssh-keygen -t ed25519 -f "${SSH_DIR}/ssm-ssh-tmp" -C 'ssh-over-ssm' -N ''
    fi
    trap cleanup EXIT
    ssh_pubkey="$(cat "${SSH_DIR}/ssm-ssh-tmp.pub")"
  fi

  ssm_cmd=$(cat <<EOF
"u=\"\$(getent passwd \"${2}\")\" && x=\"\$(echo \$u | cut -d: -f6)\" || exit 1
[ ! -d \"\${x}/.ssh\" ] && install -d -m700 -o\"${2}\" \"\${x}/.ssh\"
grep '${ssh_pubkey}' \"\${x}/${ssh_authkeys}\" && exit 0
printf '${ssh_pubkey}\n' | tee -a \"\${x}/${ssh_authkeys}\" || exit 1
(sleep 60 && sed -i '\|${ssh_pubkey}|d' \"\${x}/${ssh_authkeys}\" &) > /dev/null 2>&1"
EOF
  )

  # put our public key on the remote server
  command_id="$(aws ssm send-command \
    --instance-ids "$1" \
    --document-name "AWS-RunShellScript" \
    --parameters commands="${ssm_cmd}" \
    --comment "temporary ssm ssh access" \
    --output text \
    --query 'Command.CommandId')"

  # wait for successful send-command execution
  # aws ssm wait command-executed --instance-id "$1" --command-id "${command_id}"

  while true ; do
    command_result="$(aws ssm get-command-invocation --command-id "${command_id}" --instance-id "$1" --query 'Status' --output text)"
    if [ "${command_result}" = "InProgress" ]; then
      echo -n '.'
      sleep 2
      continue
    fi
    break
  done
  echo

  # start ssh session over ssm
  aws ssm start-session --document-name AWS-StartSSHSession --target "$1"
}

checks () {
  if [[ "$#" -ne 2 ]]; then
    die "usage: ${0##*/} <instance-id> <ssh user>"
  elif [[ ! "$1" =~ ^i-([0-9a-f]{8,})$ ]]; then
    die "error: invalid instance-id"
  elif [[ "$(basename -- "$(ps -o comm= -p $PPID)")" != "ssh" ]]; then
    ssh -o IdentityFile="${SSH_DIR}/ssm-ssh-tmp" -o ProxyCommand="${0} ${1} ${2}" "${2}@${1}"
    exit 0
  fi

  if [[ -z "${AWS_PROFILE:-}" ]]; then
    echo "Error: please set AWS profile first" >&2
    exit 1
  fi
}

checks "$@"
main "$@"