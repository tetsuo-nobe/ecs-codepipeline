"""
ECS Blue/Green デプロイメント ライフサイクルフック用 Lambda 関数

環境変数 VALIDATION_RESULT の値によってデプロイの続行・ロールバックを制御する。
  - SUCCESS : デプロイを続行する
  - FAIL    : デプロイを失敗させてロールバックをトリガーする

ECS はこの関数の戻り値の hookStatus を確認し、デプロイの次のステージに進むか
ロールバックするかを判断する。
CodePipeline 経由のデプロイでも、ECS サービスに設定されたフックとして同様に呼び出される。

※ ecs-infrastructure.yaml にはこのコードがインラインで埋め込まれています。
"""

import os
import json


def handler(event, context):
    """ECS ライフサイクルフックのエントリーポイント"""

    print(f"ライフサイクルフック呼び出し: {json.dumps(event)}")

    # 環境変数から検証結果を取得（デフォルトは SUCCESS）
    validation_result = os.environ.get("VALIDATION_RESULT", "SUCCESS").upper()

    print(f"VALIDATION_RESULT = {validation_result}")

    if validation_result == "FAIL":
        print("検証失敗: デプロイをロールバックします")
        return {
            "hookStatus": "FAILED"
        }

    print("検証成功: デプロイを続行します")
    return {
        "hookStatus": "SUCCEEDED"
    }
