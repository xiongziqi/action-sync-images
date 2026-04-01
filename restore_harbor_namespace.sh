#!/usr/bin/env bash
# ==============================================================================
# 恢复 Harbor 中丢失的命名空间 (Namespace) 的镜像
#
# 描述: 
#   基于给定的同步配置文件，本脚本将提取原镜像的 namespace（例如 nvcr.io/nvidia/pytorch 中的 nvidia），
#   自动在本地 Harbor 中重建对应的项目 (Project)，然后再通过 skopeo 将 library 下被去除了前缀的镜像
#   拷贝到新建的项目下，还原丢失的命名空间路径。
#
# 前置条件:
#   1. 安装有 skopeo 命令和 curl 命令
#   2. 该节点可以连接至 Harbor 服务器
# ==============================================================================

set -e

# ================= Configuration (下面信息请根据你的实际 Harbor 配置修改) =================
HARBOR_PROTO="http"                   # Harbor 的协议 (http 或 https，内网一般配 http 即可)
HARBOR_HOST="192.168.1.100"           # Harbor 域名或IP (注意不要带 http:// 前缀)
HARBOR_USER="admin"                   # Harbor 管理员用户名
HARBOR_PASS="Harbor12345"             # Harbor 管理员密码
TLS_VERIFY="false"                    # 是否验证 TLS 证书 (如果为 http 或自签证书，留 false)

YML_FILE=".github/workflows/sync-images-dockerHub-example..yml" # 从该 YAML 提取对应关系
# ==============================================================================================

# 基础依赖检查
if ! command -v skopeo &> /dev/null; then
    echo "[!] skopeo command could not be found. Please install it first."
    exit 1
fi
if ! command -v curl &> /dev/null; then
    echo "[!] curl command could not be found."
    exit 1
fi
if [ ! -f "$YML_FILE" ]; then
    echo "[!] File $YML_FILE not found in the current directory."
    exit 1
fi

CURL_OPTS="-s"
if [ "$TLS_VERIFY" == "false" ]; then
    CURL_OPTS="-s -k" 
fi

echo "[*] Logging into Skopeo for $HARBOR_HOST..."
skopeo login "$HARBOR_HOST" -u "$HARBOR_USER" -p "$HARBOR_PASS" --tls-verify=$TLS_VERIFY

echo "--------------------------------------------------------"
echo "[*] Parsing $YML_FILE and starting namespace restoration..."
echo "--------------------------------------------------------"

# 提取并逐行解析 sync_image 命令
grep -E '^\s*sync_image\s+"' "$YML_FILE" | while read -r line; do
    
    # 拆分参数。xargs 会剥离双引号
    read -ra args <<< "$(echo "$line" | xargs)"
    
    ORIG_IMAGE="${args[1]}"   # 源镜像如: nvcr.io/nvidia/pytorch:25.12-py3
    TARGET_NAME="${args[2]}"  # 在 library 中的新名字如: pytorch
    TARGET_TAG="${args[3]}"   # 标签如: 25.12-py3
    
    if [ -z "$ORIG_IMAGE" ] || [ -z "$TARGET_NAME" ]; then
        continue
    fi

    # 去掉 Tag (如 25.12-py3)，只保留路径段 nvcr.io/nvidia/pytorch
    ORIG_RAW="${ORIG_IMAGE%:*}" 
    
    # 根据 '/' 分割原镜像提取命名空间结构
    IFS='/' read -ra PARTS <<< "$ORIG_RAW"
    
    # 判定第一个部分如果是域名(带有点或者为localhost)，则踢除，以便提取后续 namespace
    if [[ "${PARTS[0]}" == *.* || "${PARTS[0]}" == "localhost" ]]; then
        PARTS=("${PARTS[@]:1}")
    fi
    
    if [ ${#PARTS[@]} -eq 1 ]; then
        # 例如 docker.io/python，解析后只剩下 python
        # 这类官方镜像默认归属于 library 空间
        PROJECT="library"
        REPO_PATH="${PARTS[0]}"
    else
        # Harbor 中的 Project 名称对应原有前缀第一层 Namespace (例如 nvidia)
        PROJECT="${PARTS[0]}"
        # 将剩余部分拼接作为完整仓库名 (例如 mellanox/ib-sriov-cni 这里处理多层级路径，Harbor支持/分隔的repo名称)
        REPO_PATH=$(IFS='/'; echo "${PARTS[*]}")
    fi
    
    # 无需处理本来就在 library 空间的镜像
    if [ "$PROJECT" == "library" ]; then
        echo "[-] Skipping $ORIG_IMAGE, it belongs to 'library' namespace logically."
        continue
    fi

    echo "================================================="
    echo "Processing target: $ORIG_IMAGE"
    
    CURRENT_HARBOR_IMAGE="$HARBOR_HOST/library/$TARGET_NAME:$TARGET_TAG"
    NEW_HARBOR_IMAGE="$HARBOR_HOST/$REPO_PATH:$TARGET_TAG"
    
    echo "  -> Namespace/Project Target : $PROJECT"
    echo "  -> Repository Path          : $REPO_PATH"
    echo "  -> Moving From [Library]    : $CURRENT_HARBOR_IMAGE"
    echo "  -> To Destination [Target]  : $NEW_HARBOR_IMAGE"
    
    # ==============================================================
    # 1. 使用 Harbor API 自动创建对应的 Project 仓库
    # ==============================================================
    HTTP_CODE=$(curl $CURL_OPTS -o /dev/null -w "%{http_code}" -X POST "${HARBOR_PROTO}://${HARBOR_HOST}/api/v2.0/projects" \
        -u "${HARBOR_USER}:${HARBOR_PASS}" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\": \"${PROJECT}\", \"metadata\": {\"public\": \"true\"}}")
        
    if [ "$HTTP_CODE" -eq 201 ]; then
        echo "  [+] Automatically created project '$PROJECT' in Harbor."
    elif [ "$HTTP_CODE" -eq 409 ]; then
         echo "  [+] Project '$PROJECT' already exists."
    elif [ "$HTTP_CODE" -eq 401 ] || [ "$HTTP_CODE" -eq 403 ]; then
        echo "  [!] Authentication failed ($HTTP_CODE). Please check your Harbor Username & Password."
        exit 1
    elif [ "$HTTP_CODE" -eq 000 ]; then
        echo "  [!] Failed to connect to Harbor via Curl. Check HARBOR_PROTO or HARBOR_HOST."
        exit 1
    elif [ "$HTTP_CODE" -ge 400 ]; then
        echo "  [!] Error creating project '$PROJECT'. HTTP Code: $HTTP_CODE"
    fi
    
    # ==============================================================
    # 2. Skopeo 执行 Harbor 内部空间镜像拷贝
    # ==============================================================
    echo "  [=>] Initiating Skopeo copy..."
    # 检查待移动的镜像是否已经在新目录存在
    if skopeo inspect --tls-verify=$TLS_VERIFY "docker://$NEW_HARBOR_IMAGE" >/dev/null 2>&1; then
        echo "  [SKIP] Destination image $NEW_HARBOR_IMAGE already exists."
    else
        # --all 拷贝所有架构(假如多架构存在的话)，还原原始一致性结构
        if skopeo copy --all \
            --src-tls-verify=$TLS_VERIFY --dest-tls-verify=$TLS_VERIFY \
            "docker://$CURRENT_HARBOR_IMAGE" \
            "docker://$NEW_HARBOR_IMAGE"; then
            echo "  [OK] Successfully transplanted to $NEW_HARBOR_IMAGE"
        else
            echo "  [!] [WARNING] Failed to copy image. The source image ($CURRENT_HARBOR_IMAGE) might be missing in library. Skipping..."
        fi
    fi

done

echo ""
echo "[*] Script Finished! All defined namespaces and their images have been restored."
