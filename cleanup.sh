#!/usr/bin/env bash
# ============================================================
# CodePipeline による ECS Blue/Green デプロイ ハンズオン
# 環境クリーンアップスクリプト（講師用）
#
# 削除対象:
#   - EventBridge ルール（myweb-pipeline を起動するルール）
#   - CodePipeline パイプライン myweb-pipeline
#   - CodeBuild プロジェクト myweb-build
#   - CodeCommit リポジトリ myweb-app
#   - ECR リポジトリ myweb（イメージを含む）
#   - CloudFormation スタック ecs-blue-green
#     （VPC・ALB・ECS クラスター/サービス・Lambda・IAM ロールなど）
#   - タスク定義 myweb-task の ACTIVE なリビジョン
#   - コンソールで自動作成された IAM ロールとポリシー
#     （ロール名に myweb-pipeline または myweb-build を含むもの）
#   - ロググループ /aws/codebuild/myweb-build、/aws/lambda/ecs-deployment-hook
#   - アーティファクトストアの S3 バケット（codepipeline-<リージョン>-*）
#     ※ほかのパイプラインと共用している場合は myweb-pipeline/ フォルダだけを削除
#   - CloudShell 上の ~/myweb-app
#
# 使い方（CloudShell で実行）:
#   bash cleanup.sh       # 削除対象を表示し、確認してから実行
#   bash cleanup.sh -y    # 確認なしで実行
#
# 存在しないリソースはスキップするため、途中で失敗した場合も再実行できます。
# ============================================================
set -uo pipefail

# ------------------------------------------------------------
# 設定値（ハンズオンで作成したリソース名）
# ------------------------------------------------------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
PIPELINE_NAME="myweb-pipeline"
CODEBUILD_PROJECT="myweb-build"
CODECOMMIT_REPOSITORY="myweb-app"
ECR_REPOSITORY="myweb"
STACK_NAME="ecs-blue-green"
TASK_FAMILY="myweb-task"
LOG_GROUPS=("/aws/codebuild/myweb-build" "/aws/lambda/ecs-deployment-hook")
LOCAL_REPO_DIR="$HOME/myweb-app"

ASSUME_YES=false
if [[ "${1:-}" == "-y" ]]; then
  ASSUME_YES=true
fi

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

# ------------------------------------------------------------
# 事前確認
# ------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [[ -z "$ACCOUNT_ID" ]]; then
  warn "AWS の認証情報を取得できません。AWS CLI の設定を確認してください。"
  exit 1
fi
PIPELINE_ARN="arn:aws:codepipeline:${REGION}:${ACCOUNT_ID}:${PIPELINE_NAME}"

# 削除対象の IAM ロール（コンソールで自動作成されたもの）
ROLE_NAMES=$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'${PIPELINE_NAME}') || contains(RoleName,'${CODEBUILD_PROJECT}')].RoleName" \
  --output text)

# アーティファクトストアの S3 バケット候補
BUCKETS=$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'codepipeline-${REGION}-')].Name" --output text)

cat <<EOF
============================================================
 CodePipeline ハンズオン環境を削除します
============================================================
 アカウント       : $ACCOUNT_ID
 リージョン       : $REGION
 パイプライン     : $PIPELINE_NAME（起動用の EventBridge ルールを含む）
 CodeBuild        : $CODEBUILD_PROJECT
 CodeCommit       : $CODECOMMIT_REPOSITORY
 ECR リポジトリ   : $ECR_REPOSITORY（イメージを含む）
 スタック         : $STACK_NAME
 タスク定義       : $TASK_FAMILY
 IAM ロール       : ${ROLE_NAMES:-（なし）}
 ロググループ     : ${LOG_GROUPS[*]}
 S3 バケット      : ${BUCKETS:-（なし）}
                    ※ほかのパイプラインと共用の場合は ${PIPELINE_NAME}/ のみ削除
 ローカル         : $LOCAL_REPO_DIR
============================================================
EOF

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "削除を実行しますか？ (yes/no): " answer
  if [[ "$answer" != "yes" ]]; then
    info "中止しました。"
    exit 0
  fi
fi

# ------------------------------------------------------------
# 1. EventBridge ルールの削除（パイプラインをターゲットにしているルール）
# ------------------------------------------------------------
delete_eventbridge_rules() {
  local rules rule target_ids
  rules=$(aws events list-rule-names-by-target --target-arn "$PIPELINE_ARN" \
    --query "RuleNames[]" --output text --region "$REGION")
  if [[ -z "$rules" ]]; then
    info "EventBridge ルールは存在しません（スキップ）"
    return
  fi
  for rule in $rules; do
    # ルールはターゲットを外してから削除する
    target_ids=$(aws events list-targets-by-rule --rule "$rule" \
      --query "Targets[].Id" --output text --region "$REGION")
    if [[ -n "$target_ids" ]]; then
      # shellcheck disable=SC2086
      aws events remove-targets --rule "$rule" --ids $target_ids --region "$REGION" >/dev/null
    fi
    aws events delete-rule --name "$rule" --region "$REGION"
    info "EventBridge ルールを削除しました: $rule"
  done
}

# ------------------------------------------------------------
# 2. パイプラインの削除
# ------------------------------------------------------------
delete_pipeline() {
  if ! aws codepipeline get-pipeline --name "$PIPELINE_NAME" --region "$REGION" >/dev/null 2>&1; then
    info "パイプライン $PIPELINE_NAME は存在しません（スキップ）"
    return
  fi
  aws codepipeline delete-pipeline --name "$PIPELINE_NAME" --region "$REGION"
  info "パイプラインを削除しました: $PIPELINE_NAME"
}

# ------------------------------------------------------------
# 3. CodeBuild プロジェクトの削除
# ------------------------------------------------------------
delete_codebuild_project() {
  local found
  found=$(aws codebuild batch-get-projects --names "$CODEBUILD_PROJECT" \
    --query "projects[].name" --output text --region "$REGION")
  if [[ -z "$found" ]]; then
    info "CodeBuild プロジェクト $CODEBUILD_PROJECT は存在しません（スキップ）"
    return
  fi
  aws codebuild delete-project --name "$CODEBUILD_PROJECT" --region "$REGION" >/dev/null
  info "CodeBuild プロジェクトを削除しました: $CODEBUILD_PROJECT"
}

# ------------------------------------------------------------
# 4. CodeCommit リポジトリの削除
# ------------------------------------------------------------
delete_codecommit_repository() {
  if ! aws codecommit get-repository --repository-name "$CODECOMMIT_REPOSITORY" --region "$REGION" >/dev/null 2>&1; then
    info "CodeCommit リポジトリ $CODECOMMIT_REPOSITORY は存在しません（スキップ）"
    return
  fi
  aws codecommit delete-repository --repository-name "$CODECOMMIT_REPOSITORY" --region "$REGION" >/dev/null
  info "CodeCommit リポジトリを削除しました: $CODECOMMIT_REPOSITORY"
}

# ------------------------------------------------------------
# 5. ECR リポジトリの削除（イメージを含む）
# ------------------------------------------------------------
delete_ecr_repository() {
  if ! aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$REGION" >/dev/null 2>&1; then
    info "ECR リポジトリ $ECR_REPOSITORY は存在しません（スキップ）"
    return
  fi
  aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --force --region "$REGION" >/dev/null
  info "ECR リポジトリを削除しました: $ECR_REPOSITORY"
}

# ------------------------------------------------------------
# 6. CloudFormation スタックの削除
# ------------------------------------------------------------
delete_stack() {
  if ! aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" >/dev/null 2>&1; then
    info "スタック $STACK_NAME は存在しません（スキップ）"
    return
  fi
  info "スタック $STACK_NAME を削除します（完了まで数分かかります）"
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  if aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"; then
    info "スタック $STACK_NAME を削除しました"
  else
    warn "スタック $STACK_NAME の削除に失敗しました。CloudFormation コンソールでイベントを確認してください"
  fi
}

# ------------------------------------------------------------
# 7. タスク定義の登録解除（CodePipeline が登録したリビジョンを含む）
# ------------------------------------------------------------
deregister_task_definitions() {
  local arn arns count=0
  arns=$(aws ecs list-task-definitions --family-prefix "$TASK_FAMILY" --status ACTIVE \
    --query "taskDefinitionArns[]" --output text --region "$REGION")
  for arn in $arns; do
    # family-prefix は前方一致のため、ファミリー名が完全一致するものだけを対象にする
    if [[ "$arn" == *":task-definition/${TASK_FAMILY}:"* ]]; then
      aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" >/dev/null
      count=$((count + 1))
    fi
  done
  info "タスク定義 $TASK_FAMILY のリビジョンを ${count} 件登録解除しました"
}

# ------------------------------------------------------------
# 8. IAM ロールとポリシーの削除（コンソールで自動作成されたもの）
# ------------------------------------------------------------
delete_iam_roles() {
  local role policy_arn policy_name attachment_count v
  if [[ -z "$ROLE_NAMES" ]]; then
    info "削除対象の IAM ロールはありません（スキップ）"
    return
  fi
  for role in $ROLE_NAMES; do
    # アタッチされている管理ポリシーを外す
    for policy_arn in $(aws iam list-attached-role-policies --role-name "$role" \
        --query "AttachedPolicies[].PolicyArn" --output text); do
      aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn"
      # カスタマー管理ポリシー（自アカウントのポリシー）は、ほかで使われていなければ削除する
      # AWS 管理ポリシー（AmazonEC2ContainerRegistryPowerUser など）は外すだけ
      if [[ "$policy_arn" == arn:aws:iam::${ACCOUNT_ID}:* ]]; then
        attachment_count=$(aws iam get-policy --policy-arn "$policy_arn" \
          --query "Policy.AttachmentCount" --output text)
        if [[ "$attachment_count" == "0" ]]; then
          # デフォルト以外のバージョンを削除してからポリシーを削除する
          for v in $(aws iam list-policy-versions --policy-arn "$policy_arn" \
              --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text); do
            aws iam delete-policy-version --policy-arn "$policy_arn" --version-id "$v"
          done
          aws iam delete-policy --policy-arn "$policy_arn"
          info "IAM ポリシーを削除しました: $policy_arn"
        fi
      fi
    done
    # インラインポリシーを削除する
    for policy_name in $(aws iam list-role-policies --role-name "$role" \
        --query "PolicyNames[]" --output text); do
      aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name"
    done
    if aws iam delete-role --role-name "$role"; then
      info "IAM ロールを削除しました: $role"
    else
      warn "IAM ロール $role の削除に失敗しました"
    fi
  done
}

# ------------------------------------------------------------
# 9. ロググループの削除
# ------------------------------------------------------------
delete_log_groups() {
  local group found
  for group in "${LOG_GROUPS[@]}"; do
    found=$(aws logs describe-log-groups --log-group-name-prefix "$group" \
      --query "logGroups[?logGroupName=='$group'].logGroupName" --output text --region "$REGION")
    if [[ -z "$found" ]]; then
      info "ロググループ $group は存在しません（スキップ）"
      continue
    fi
    aws logs delete-log-group --log-group-name "$group" --region "$REGION"
    info "ロググループを削除しました: $group"
  done
}

# ------------------------------------------------------------
# 10. アーティファクトストアの S3 バケットの削除
# ------------------------------------------------------------
# 指定したプレフィックス配下のオブジェクトを、全バージョン（削除マーカーを含む）削除する
# バージョニングが有効なバケットでも削除できるよう、list-object-versions を使う
purge_objects() {
  local bucket="$1" prefix="$2" objects
  while :; do
    objects=$(aws s3api list-object-versions --bucket "$bucket" --prefix "$prefix" --max-items 500 \
      --query "[Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]" \
      --output json --region "$REGION" 2>/dev/null)
    if [[ -z "$objects" || "$objects" == "[]" || "$objects" == "null" ]]; then
      break
    fi
    aws s3api delete-objects --bucket "$bucket" \
      --delete "{\"Objects\":${objects},\"Quiet\":true}" --region "$REGION" >/dev/null || break
  done
}

delete_artifact_buckets() {
  local bucket prefixes other p
  if [[ -z "$BUCKETS" ]]; then
    info "アーティファクトストアの S3 バケットはありません（スキップ）"
    return
  fi
  for bucket in $BUCKETS; do
    # バケット直下のフォルダ（パイプラインごとのプレフィックス）を確認する
    prefixes=$(aws s3api list-objects-v2 --bucket "$bucket" --delimiter "/" \
      --query "CommonPrefixes[].Prefix" --output text --region "$REGION" 2>/dev/null)
    other=""
    for p in $prefixes; do
      if [[ "$p" != "None" && "$p" != "${PIPELINE_NAME}/" ]]; then
        other="$other $p"
      fi
    done
    if [[ -n "$other" ]]; then
      # ほかのパイプラインと共用しているため、このハンズオンのフォルダだけを削除する
      purge_objects "$bucket" "${PIPELINE_NAME}/"
      info "S3 バケット $bucket はほかのパイプラインと共用のため、${PIPELINE_NAME}/ のみ削除しました（残したフォルダ:${other}）"
    else
      purge_objects "$bucket" ""
      if aws s3api delete-bucket --bucket "$bucket" --region "$REGION"; then
        info "S3 バケットを削除しました: $bucket"
      else
        warn "S3 バケット $bucket の削除に失敗しました"
      fi
    fi
  done
}

# ------------------------------------------------------------
# 11. CloudShell 上のローカルリポジトリの削除
# ------------------------------------------------------------
delete_local_repo() {
  if [[ ! -d "$LOCAL_REPO_DIR" ]]; then
    info "$LOCAL_REPO_DIR は存在しません（スキップ）"
    return
  fi
  rm -rf "$LOCAL_REPO_DIR"
  info "ローカルリポジトリを削除しました: $LOCAL_REPO_DIR"
}

delete_eventbridge_rules
delete_pipeline
delete_codebuild_project
delete_codecommit_repository
delete_ecr_repository
delete_stack
deregister_task_definitions
delete_iam_roles
delete_log_groups
delete_artifact_buckets
delete_local_repo

info "クリーンアップが完了しました"
