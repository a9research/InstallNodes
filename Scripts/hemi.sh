#!/bin/bash

# 设置版本号
current_version=20241205001

# 定义基础目录和节点计数器文件
BASE_DIR="/home/HEMI"
NODE_COUNTER_FILE="${BASE_DIR}/.hemi_node_counter"

# 确保基础目录存在
mkdir -p "$BASE_DIR"

# 初始化节点计数器
if [ ! -f "$NODE_COUNTER_FILE" ]; then
    echo "1" > "$NODE_COUNTER_FILE"
fi

# 获取下一个节点编号
get_next_node_number() {
    local counter_value
    counter_value=$(cat "$NODE_COUNTER_FILE")
    ((counter_value++))
    echo "$counter_value"
    echo "$counter_value" > "$NODE_COUNTER_FILE"  # 更新计数器文件
}

update_script() {
    # 指定URL
    update_url="https://raw.githubusercontent.com/a9research/InstallNodes/refs/heads/main/Scripts/hemi.sh"
    file_name=$(basename "$update_url")

    # 下载脚本文件
    tmp=$(date +%s)
    timeout 10s curl -s -o "$HOME/$tmp" -H "Cache-Control: no-cache" "$update_url?$tmp"
    exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        echo "命令超时"
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        echo "下载失败"
        return 1
    fi

    # 检查是否有新版本可用
    latest_version=$(grep -oP 'current_version=([0-9]+)' $HOME/$tmp | sed -n 's/.*=//p')

    if [[ "$latest_version" -gt "$current_version" ]]; then
        clear
        echo ""
        # 提示需要更新脚本
        printf "\033[31m脚本有新版本可用！当前版本：%s，最新版本：%s\033[0m\n" "$current_version" "$latest_version"
        echo "正在更新..."
        sleep 3
        mv $HOME/$tmp $HOME/$file_name
        chmod +x $HOME/$file_name
        exec "$HOME/$file_name"
    else
        # 脚本是最新的
        rm -f $tmp
    fi

}

function install_common_files() {
    # 检查公共工作文件是否已经安装
    if [ -d "${BASE_DIR}/heminetwork" ]; then
        echo "公共工作文件已安装。"
        return
    fi

    # 安装依赖
    sudo apt update
    sudo apt install -y jq git make

    # 检查是否已安装Go
    if command -v go >/dev/null 2>&1; then
        echo "Go已安装。"
    else
        # 安装GO
        sudo rm -rf /usr/local/go
        wget https://go.dev/dl/go1.23.2.linux-amd64.tar.gz -P /tmp/
        sudo tar -C /usr/local -xzf /tmp/go1.23.2.linux-amd64.tar.gz
        echo "export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin" >> ~/.bashrc
        export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
        go version
    fi

    # 克隆代码并安装
    git clone https://github.com/hemilabs/heminetwork.git "${BASE_DIR}/heminetwork"
    cd "${BASE_DIR}/heminetwork"
    make deps
    make install
}


# 节点安装功能
function install_node() {
    local node_number=$1
    local node_name="Hemi$(printf '%03d\n' $node_number)"
    local node_config_path="${BASE_DIR}/${node_name}_config"

    FEE=$(curl -s https://mempool.space/testnet/api/v1/fees/recommended | sed -n 's/.*"fastestFee":\([0-9.]*\).*/\1/p')
    read -p "设置gas(参考值：$FEE)：" POPM_STATIC_FEE

    # 生成密钥
    ./bin/keygen -secp256k1 -json -net="testnet" > "${node_config_path}/popm-address.json"
    POPM_BTC_PRIVKEY=$(jq -r '.private_key' "${node_config_path}/popm-address.json")
    POPM_BTC_PUBKEY=$(jq -r '.pubkey_hash' "${node_config_path}/popm-address.json")

	POPM_BFG_URL="wss://testnet.rpc.hemi.network/v1/ws/public"
    
    # 创建systemd服务文件
    sudo tee /lib/systemd/system/${node_name}.service > /dev/null <<EOF
[Unit]
Description=${node_name} Service
[Service]
Type=simple
Restart=always
RestartSec=30s
WorkingDirectory=${BASE_DIR}/heminetwork
Environment=POPM_BTC_PRIVKEY=${POPM_BTC_PRIVKEY}
Environment=POPM_STATIC_FEE=${POPM_STATIC_FEE}
Environment=POPM_BFG_URL=${POPM_BFG_URL}
ExecStart=${BASE_DIR}/heminetwork/bin/popmd
[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable ${node_name}
    sudo systemctl start ${node_name}

    printf "\033[31m部署完成，请给：%s，领水\033[0m\n" "$POPM_BTC_PUBKEY"
}

# 添加节点实例
function add_node() {
    local node_number
    node_number=$(get_next_node_number)

    # 如果是第一个节点实例，安装公共工作文件
    if [ $node_number -eq 1 ]; then
        install_common_files
    fi

    install_node $node_number
}

# 导出节点钱包信息
function export_wallet_info() {
    # 列出所有节点实例的配置文件
    echo "以下是所有节点实例的钱包信息："
    for config_dir in ${BASE_DIR}/hemi*_config; do
        if [ -d "$config_dir" ]; then
            # 从配置目录名中提取节点名称
            node_name=$(basename "$config_dir")

            # 读取私钥和公钥信息
            priv_key_file="${config_dir}/popm-address.json"

            if [ -f "$priv_key_file" ]; then
                priv_key=$(jq -r '.private_key' "$priv_key_file")
                pub_key=$(jq -r '.public_key' "$priv_key_file")
                pub_key_hash=$(jq -r '.pubkey_hash' "$priv_key_file")
                eth_addr=$(jq -r '.ethereum_address' "$priv_key_file")

                # 展示节点的私钥和公钥信息
                echo "节点 $node_name 的钱包信息："
                echo "私钥: $priv_key"
                echo "公钥: $pub_key"
                echo "公钥哈希: $pub_key_hash"
                echo "EVM地址: $eth_addr"
                echo "----------------------------------"
            else
                echo "节点 $node_name 没有找到有效的密钥文件。"
            fi
        fi
    done
}

# 查看日志
function view_logs(){
	sudo journalctl -u hemi.service -f --no-hostname -o cat
}

# 查看节点状态
function view_status(){
	sudo systemctl status hemi
}

# 停止节点
function stop_node() {
    # 遍历所有节点服务文件
    for service_file in /lib/systemd/system/hemi*.service; do
        if [ -f "$service_file" ]; then
            # 从服务文件名中提取节点名称
            node_name=$(basename "$service_file" .service)
            
            # 停止节点服务
            sudo systemctl stop "$node_name"
        fi
    done

    echo "所有节点已停止。"
}

# 启动节点
function start_node() {
    # 遍历所有节点服务文件
    for service_file in /lib/systemd/system/hemi*.service; do
        if [ -f "$service_file" ]; then
            # 从服务文件名中提取节点名称
            node_name=$(basename "$service_file" .service)
            
            # 启动节点服务
            sudo systemctl start "$node_name"
        fi
    done

    echo "所有节点已启动。"
}

# 更改gas
function update_gas(){
    local new_gas_fee
    # 获取参考值
    FEE=$(curl -s https://mempool.space/testnet/api/v1/fees/recommended | sed -n 's/.*"fastestFee": $[0-9.]*$ .*/\1/p')
    # 提示用户输入新的Gas费用
    read -p "设置新的gas费用(参考值：$FEE)：" new_gas_fee

    # 遍历所有节点服务文件
    for service_file in /lib/systemd/system/hemi*.service; do
        if [ -f "$service_file" ]; then
            # 从服务文件名中提取节点名称
            node_name=$(basename "$service_file" .service)
            
            # 更新Gas值
            sudo sed -i "s/Environment=POPM_STATIC_FEE=[0-9.]*/Environment=POPM_STATIC_FEE=$new_gas_fee/" "$service_file"
            
            # 重新加载服务并重启节点
            sudo systemctl daemon-reload
            sudo systemctl restart "$node_name"
        fi
    done

    echo "所有节点的Gas值已更新为：$new_gas_fee"
}

# 更新程序代码
function check_and_upgrade {
    # 进入项目目录
    project_folder="heminetwork"

    cd ~/$project_folder || { echo "Directory ~/$project_folder does not exist."; exit 1; }

    # 获取本地版本
    local_version=$(git describe --tags --abbrev=0)

    # 获取远程版本
    git fetch --tags
    remote_version=$(git describe --tags $(git rev-list --tags --max-count=1))

    echo "本地程序版本: $local_version"
    echo "官方程序版本: $remote_version"

    # 比较版本，如果本地版本低于远程版本，则询问用户是否进行升级
    if [ "$local_version" != "$remote_version" ]; then
        read -p "发现官方发布了新的程序版本，是否要升级到： $remote_version? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "正在升级..."
            stop_node
            git checkout $remote_version
            git submodule update --init --recursive
            make deps
            make install
            start_node
            echo "升级完成，当前本地程序版本： $remote_version."
        else
            echo "取消升级，当前本地程序版本： $local_version."
        fi
    else
        echo "已经是最新版本: $local_version."
    fi
}

# 卸载节点功能
function uninstall_node() {
    echo "确定要卸载所有节点程序吗？这将会删除所有相关的数据和服务。[Y/N]"
    read -r -p "请确认: " response

    case "$response" in
        [yY][eE][sS]|[yY]) 
            echo "开始卸载所有节点程序..."
            stop_node  # 停止所有节点服务

            # 删除所有节点的服务文件
            for service_file in /lib/systemd/system/hemi*.service; do
                if [ -f "$service_file" ]; then
                    sudo rm "$service_file"
                fi
            done

            # 删除工作目录
            rm -rf "$BASE_DIR/heminetwork"

            # 重新加载systemd管理器配置
            sudo systemctl daemon-reload

            echo "所有节点程序卸载完成。"
            ;;
        *)
            echo "取消卸载操作。"
            ;;
    esac
}


# 代码更新
update_code () {
    local repo_path="$BASE_DIR/heminetwork"
    
    # 进入项目目录
    cd "$repo_path" || { echo "Failed to enter directory: $repo_path"; return 1; }

    # 获取远程更新
    git fetch origin

    # 检查远程是否有更新
    local updates=$(git log HEAD..origin/main --oneline)

    if [ -n "$updates" ]; then
        echo "发现新代码:"
        echo "$updates"
        echo "正在更新..."
        git pull origin main
    else
        echo "完成更新..."
    fi
}

# 导入钱包
function import_wallet() {
    # 列出所有节点实例
    echo "请选择要导入钱包私钥的节点实例："
    nodes=(/lib/systemd/system/hemi*.service)
    for index in "${!nodes[@]}"; do
        service_file=${nodes[index]}
        node_name=$(basename "$service_file" .service)
        echo "$((index+1)). $node_name"
    done

    # 用户选择节点实例
    read -p "请输入节点编号: " node_choice
    node_service=${nodes[$node_choice-1]}
    node_name=$(basename "$node_service" .service)

    # 检查用户输入是否有效
    if [ -z "$node_name" ]; then
        echo "无效的节点编号。"
        return 1
    fi

    # 用户输入私钥
    read -p "请输入$node_name节点的私钥：" wallet_private_key

    # 更新systemd服务文件中的私钥
    sudo sed -i "s/Environment=POPM_BTC_PRIVKEY=.*/Environment=POPM_BTC_PRIVKEY=$wallet_private_key/" "$node_service"

    # 重新加载服务并重启节点
    sudo systemctl daemon-reload
    sudo systemctl restart "$node_name"

    echo "节点 $node_name 的钱包私钥已更新。"
}



# 主菜单
function main_menu() {
    while true; do
        clear
        echo "===================Hemi Network一键部署脚本==================="
        echo "当前版本：$current_version"
        echo "沟通电报群：https://t.me/lumaogogogo"
        echo "推荐配置：2C4G100G"
        echo "请选择要执行的操作:"
        echo "1. 添加节点 add_node"
        echo "2. 节点状态 view_status"
        echo "3. 节点日志 view_logs"
        echo "4. 停止节点 stop_node"
        echo "5. 启动节点 start_node"
        echo "6. 修改gas update_gas"
        echo "7. 更新代码 update_code"
        echo "8. 导入钱包 import_wallet"
        echo "9. 导出钱包 export_wallet_info"
        echo "1618. 卸载节点 uninstall_node"
        echo "0. 退出脚本 exit"
        read -p "请输入选项: " OPTION

        case $OPTION in
        1) add_node ;;
        2) view_status ;;
        3) view_logs ;;
        4) stop_node ;;
        5) start_node ;;
        6) update_gas ;;
        7) update_code ;;
        8) import_wallet ;;
        9) export_wallet_info ;;
        1618) uninstall_node ;;
        0) echo "退出脚本。"; exit 0 ;;
        *) echo "无效选项，请重新输入。"; sleep 3 ;;
        esac
        echo "按任意键返回主菜单..."
        read -n 1
    done
}

# 检查更新
update_script

# 显示主菜单
main_menu