#!/bin/bash
#Set image.tag in charts/<chart>/values.yaml to the newest multi-arch image in the chart's ECR repository, the one Argo CD then rolls out from master.
#Usage: ./scripts/update-tags.sh [--region <region>] [--chart <name>] [--tag <tag>] [--auto-approve] [--commit] [--push]

set -euo pipefail

HELM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HELM_DIR

show_usage() {
  cat <<USAGE
Usage: $(basename "$0") [--region <region>] [--chart <name>] [--tag <tag>] [--auto-approve] [--commit] [--push]

For every chart under charts/ (or the one named with --chart), reads the newest image in the ECR repository
of the same name and writes its tag into charts/<chart>/values.yaml as image.tag. A tag counts only when its
-amd64 and -arm64 images exist too, so both node pools can pull it.

Options:
  --region <region> region of the ECR repositories; default AWS_REGION, else us-east-1
  --chart <name>    one chart only, e.g. of-api
  --tag <tag>       use this tag instead of the newest one (a rollback), with --chart
  --auto-approve    no confirmation prompt
  --commit          commit the changed values files, one commit per chart
  --push            commit and push the current branch; Argo CD syncs from master
USAGE
}


#newest tag in the repository that is an index (no -amd64/-arm64 suffix) and has both arch images
latest_tag() {
  local repository="$1" region="$2" tags tag
  tags=$(aws ecr describe-images --repository-name "${repository}" --region "${region}" \
    --query 'reverse(sort_by(imageDetails,&imagePushedAt))[].imageTags[]' --output text 2>/dev/null | tr '\t' '\n') || true
  if [[ -z "${tags}" ]]; then echo "Error: no images in ECR repository ${repository} (${region})" >&2; return 1; fi
  for tag in $(grep -v -E -- '-(amd64|arm64)$' <<<"${tags}" | grep -v -x latest); do
    if grep -q -x -F "${tag}-amd64" <<<"${tags}" && grep -q -x -F "${tag}-arm64" <<<"${tags}"; then
      echo "${tag}"
      return 0
    fi
  done
  echo "Error: no tag in ${repository} has both -amd64 and -arm64 images" >&2
  return 1
}

tag_exists() {
  aws ecr describe-images --repository-name "$1" --region "$2" --image-ids "imageTag=$3" --query 'imageDetails[0].imageTags' --output text >/dev/null 2>&1
}

current_tag() {
  awk '/^image:/{block=1; next} /^[^ ]/{block=0} block && /^  tag:/{sub(/^  tag:[ \t]*/, ""); gsub(/["'"'"']/, ""); print; exit}' "$1"
}

#rewrites only the tag line of the image block, quoted, the form of-launch rewrites later
write_tag() {
  local file="$1" tag="$2" tmp
  tmp=$(mktemp)
  awk -v tag="${tag}" '
    /^image:/ {block=1; print; next}
    /^[^ ]/ {block=0}
    block && !done && /^  tag:/ {print "  tag: \"" tag "\""; done=1; next}
    {print}
  ' "${file}" >"${tmp}"
  mv "${tmp}" "${file}"
}

main() {
  local only_chart="" pinned_tag="" auto_approve=false do_commit=false do_push=false region="${AWS_REGION:-us-east-1}"
  while (($#)); do
    case "$1" in
      --region) region="$2"; shift 2 ;;
      --chart) only_chart="$2"; shift 2 ;;
      --tag) pinned_tag="$2"; shift 2 ;;
      --auto-approve) auto_approve=true; shift ;;
      --commit) do_commit=true; shift ;;
      --push) do_commit=true; do_push=true; shift ;;
      -h | --help) show_usage; exit 0 ;;
      *) echo "Error: unknown argument '$1'" >&2; show_usage >&2; exit 1 ;;
    esac
  done
  if [[ -n "${pinned_tag}" && -z "${only_chart}" ]]; then echo "Error: --tag needs --chart" >&2; exit 1; fi

  local account
  account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || { echo "Error: no AWS credentials" >&2; exit 1; }
  echo "AWS account: ${account}, region: ${region}"

  local -a charts=() changes=()
  local chart file current new
  for file in "${HELM_DIR}"/charts/*/values.yaml; do
    chart=$(basename "$(dirname "${file}")")
    if [[ -n "${only_chart}" && "${chart}" != "${only_chart}" ]]; then continue; fi
    charts+=("${chart}")
    current=$(current_tag "${file}")
    if [[ -n "${pinned_tag}" ]]; then
      new="${pinned_tag}"
      tag_exists "${chart}" "${region}" "${new}" || { echo "Error: tag ${new} is not in ECR repository ${chart}" >&2; exit 1; }
    else
      new=$(latest_tag "${chart}" "${region}") || exit 1
    fi
    if [[ "${current}" == "${new}" ]]; then
      echo "${chart}: ${current} (up to date)"
    else
      echo "${chart}: ${current:-none} -> ${new}"
    fi
    changes+=("${chart}=${new}")
  done
  if ((${#charts[@]} == 0)); then echo "Error: no chart named '${only_chart}' under charts/" >&2; exit 1; fi

  if [[ "${auto_approve}" != true ]]; then
    read -r -p "Write these tags? (yes/no): " response
    if [[ "${response}" != "yes" && "${response}" != "y" ]]; then echo "Cancelled."; exit 0; fi
  fi

  local entry
  for entry in "${changes[@]}"; do
    chart="${entry%%=*}"; new="${entry#*=}"; file="${HELM_DIR}/charts/${chart}/values.yaml"
    write_tag "${file}" "${new}"
    if [[ "${do_commit}" == true ]] && ! git -C "${HELM_DIR}" diff --quiet -- "charts/${chart}/values.yaml"; then
      git -C "${HELM_DIR}" commit -q -m "deploy: ${chart} -> ${new}" -- "charts/${chart}/values.yaml"
      echo "committed: deploy: ${chart} -> ${new}"
    fi
  done
  if [[ "${do_push}" == true ]]; then
    git -C "${HELM_DIR}" push -q
    echo "pushed $(git -C "${HELM_DIR}" rev-parse --abbrev-ref HEAD); Argo CD picks it up on its next poll"
  elif [[ "${do_commit}" != true ]]; then
    echo "Values updated. Commit and push for Argo CD to pick up the change."
  fi
}

main "$@"
