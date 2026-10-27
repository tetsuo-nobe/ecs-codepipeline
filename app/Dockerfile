# Docker Hub のレート制限を避けるため、Amazon ECR Public の nginx イメージを使用
FROM public.ecr.aws/nginx/nginx:stable

# 表示するページの HTML を配置
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80
