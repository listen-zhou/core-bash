#!/bin/bash
# wingarden全自动化部署脚本, 分布式环境
# author: Xiong Neng
# date:   2014/07/16
#
# 安装前的准备工作：
#   NFS服务器 把安装包解压缩到上面
#   NFS服务器 sudo vim /etc/ssh/sshd_config StrictHostKeyChecking no
#   NFS服务器 放入脚本和配置文件，还有python源码，目前是在10.0.0.160上测试
#   NFS服务器 安装python3，还有包yaml和psycopg2，都使用源码安装, 这是一台centos机器
#   其他机器 orchard用户加入sudo组，然后在visudo里面把NOPASSWD放开
#   其他机器 已经安装了rpcbind和nfs-common这两个软件
#   其他机器 将NFS服务器上的pub_key一个个的加入authorized_keys文件中
#
#
# 客户端测试的时候
#   /etc/hosts文件中加入10.0.0.158 api.wingarden.net uaa.wingarden.net
#   对于每个新建应用比如应用名为newapp，那么还要添加newapp.wingarden.net

set -e

function install_python {
    echo '开始安装python3环境'
    sudo yum install -y gcc make
    if [[ ! -f /usr/bin/python3 ]]; then
        echo 'python 版本不是3，开始安装....'
        echo 'start install python3...'
        sudo yum install -y zlib-devel bzip2-devel openssl-devel ncurses-devel
        tar -jxv -f Python-3.3.0.tar.bz2
        cd Python-3.3.0
        ./configure
        sudo make install
        wait
        sudo ln -s /usr/local/bin/python3 /usr/bin/python3
        echo 'python3安装成功'
    fi  
    echo '开始安装yaml包'
    tar -zxvf PyYAML-3.11.tar.gz
    cd PyYAML-3.11
    sudo python setup.py install
    echo '安装yaml成功'
    echo '开始安装psycopg2'
    sudo yum install -y postgresql-devel
    sudo yum install -y gcc
    tar -zxvf psycopg2-2.5.3.tar.gz
    cd psycopg2-2.5.3
    sudo python setup.py install
    echo 'psycpg2安装成功...'
    echo '安装python依赖成功...'
}

function sysdb {
    if [[ $# != 2 ]]; then 
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log sysdb -- 开始部署系统数据库pgsql"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    if [[ \$(sudo netstat -tnlp |grep 5432) ]]; then
        postpid=\$(sudo netstat -tnlp |grep 5432 |awk 'NR==1 {print \$7}' |awk -F/ '{print \$1}')
        sudo kill -9 \$postpid
    fi
    cd /home/orchard/nfs/wingarden_install
    ./install.sh sysdb >/dev/null
    wait
    echo '安装sysdb成功后查看'
    if [[ \$(sudo /etc/init.d/postgresql status | grep 'is running') ]]; then
        echo 'postgresql status is running...'
    else
        echo 'Oh, No,,,postgresql wrong.'
        exit 1
    fi
    
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

function nats {
    if [[ $# != 2 ]]; then 
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log nats--开始部署Nats组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh nats >/dev/null
    wait
    echo '安装完后开始检查natsserver的状态.'
    if [[ \$(sudo /etc/init.d/nats_server status | grep 'is running') ]]; then
        echo 'Success.'
    else
        echo 'Oh No.... natsserver is wrong.'
        exit 1
    fi

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# $3: nats服务器IP地址
function gorouter {
    if [[ $# != 3 ]]; then 
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log gorouter -- 开始部署gorouter"
    ssh -l orchard "$1" "
    echo '先安装go的编译环境依赖'
    sudo aptitude install -y git mercurial bzr build-essential 1>/dev/null 2>&1
    wait
    echo '开始挂载nfs服务器'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/router
    tar -zxvf gorouter.tar.gz -C /home/orchard 1>/dev/null
    wait
    echo 'tar finished..'
    sudo sh -c 'echo \"export PATH=/home/orchard/go/bin:\$PATH\" >> /etc/profile'
    sudo sh -c 'echo \"export GOPATH=/home/orchard/gopath\" >> /etc/profile'
    source /etc/profile
    echo 'source finished.'
    wait
    go_config='/home/orchard/gopath/src/github.com/cloudfoundry/gorouter/config/config.go'
    sed -i '/defaultNatsConfig = NatsConfig/{n; s/\".*\"/\"$3\"/g;}' \$go_config
    echo 'nats ip替换完成了'
    cd /home/orchard/gopath
    echo '开始编译go'
    go get -v ./src/github.com/cloudfoundry/gorouter/...
    wait
    echo 'go编译完成了..'
    echo '检查go可执行文件'
    if [[ -f /home/orchard/gopath/bin/router ]]; then
        echo 'router可执行文件有了'
    else
        echo 'Oh, No.... router file not exists.'
        exit 1
    fi
    echo 'copy gorouter to init.d directory'
    sudo cp /home/orchard/nfs/wingarden_install/router/gorouter /etc/init.d/
    echo '启动 gorouter..'
    if [[ ! \$(ps aux |grep -v grep  |grep router) ]]; then
        sudo /etc/init.d/gorouter start
        wait
    fi
    echo '检查gorouter启动状态'
    if [[ \$(sudo /etc/init.d/gorouter status |grep -v grep | grep 'is running') ]]; then
        echo 'gorouter is running...'
    else
        echo 'Oh, No... gorouter status is wrong.'
        exit 1
    fi
    echo '设置自启动'
    sudo update-rc.d gorouter defaults 20 80
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# cloud_controller 安装
function cloud_controller {
    if [[ $# != 5 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip pgsql_ip domain_name"
        exit 1
    fi
    echo "log cloud_controller -- 开始部署cloud_controller组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh cloud_controller >/dev/null
    wait
    echo '开始修改配置文件cloud_controller.yml'
    cc_config=/home/orchard/cloudfoundry/config/cloud_controller.yml
    echo '修改external_uri地址'
    sed -i '/external_uri:/{s/: .*$/: api.$5/}' \$cc_config
    echo '修改local_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'local_route=\$local_route'
    sed -i \"/local_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改系统数据库地址'
    sed -i '/database: cloud_controller/{n; s/:.*$/: $4/}' \$cc_config
    echo '修改UAA的url'
    sed -i '/uaa:/{n; n; s/:.*$/: http:\/\/uaa.$5/}' \$cc_config
    echo '修改redis的IP地址'
    sed -i '/^redis:/{n; s/: .*$/: $4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'
    echo '修改vcap_components.'
    echo '{\"components\":[\"cloud_controller\"]}' > /home/orchard/cloudfoundry/config/vcap_components.json
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';

    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '最后启动cloud_controller...'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start cloud_controller
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait
    "
}

# UAA 安装
function uaa {
    if [[ $# != 5 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip pgsql_ip domain_name"
        exit 1
    fi
    echo "log uaa -- 开始部部署uaa组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh uaa >/dev/null
    wait
    echo '开始修改配置文件uaa.yml'
    cc_config=/home/orchard/cloudfoundry/config/uaa.yml
    echo '修改local_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'local_route=\$local_route'
    sed -i \"/local_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改系统数据库地址'
    sed -i '/5432\/uaa/{s/\/\/.*:5432/\/\/$4:5432/}' \$cc_config
    sed -i '/5432\/cloud_controller/{s/\/\/.*:5432/\/\/$4:5432/}' \$cc_config
    echo '修改UAA的uris'
    sed -i '/uris:/{n; s/uaa\..*$/uaa.$5/}' \$cc_config
    echo '修改vmc的redirect地址'
    if [[ ! \$(cat \$cc_config | grep -E 'redirect-uri:.*uaa.$5') ]]; then
        sed -i '/redirect-uri:/{s/^.*$/&,http:\/\/uaa.$5\/redirect\/vmc/}' \$cc_config
    fi
    echo '替换完成了。。。。。。。。。'
    echo '修改vcap_components.'
    echo '{\"components\":[\"cloud_controller\",\"uaa\"]}' > /home/orchard/cloudfoundry/config/vcap_components.json
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';

    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '最后启动uaa...'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start uaa
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait
    "
}

# Stager 安装
function stager {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log stager -- 开始部部署stager组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh stager >/dev/null
    wait
    echo '开始修改配置文件stager.yml'
    cc_config=/home/orchard/cloudfoundry/config/stager.yml
    echo '修改nats的IP地址'
    sed -i '/nats_uri:/{s/@.*:/@$3:/}' \$cc_config
    echo '替换完成了。。。。。。。。。'
    echo '修改vcap_components.'
    echo '{\"components\":[\"cloud_controller\",\"uaa\",\"stager\"]}' \\
        > /home/orchard/cloudfoundry/config/vcap_components.json
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';

    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '最后启动stager...'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start stager
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait
    "
}

# HealthManager 安装
function health_manager {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip sysdb_ip"
        exit 1
    fi
    echo "log health_manager -- 开始部部署health_manager组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh health_manager >/dev/null
    wait
    echo '开始修改配置文件health_manager.yml'
    cc_config=/home/orchard/cloudfoundry/config/health_manager.yml
    echo '修改local_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'local_route=\$local_route'
    sed -i \"/local_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改系统数据库地址'
    sed -i '/database: cloud_controller/{n; s/:.*$/: $4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'
    echo '修改vcap_components.'
    echo '{\"components\":[\"cloud_controller\",\"uaa\",\"stager\",\"health_manager\"]}' \\
        > /home/orchard/cloudfoundry/config/vcap_components.json
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';

    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '最后启动health_manager...'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start health_manager
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait
    "
}

# DEA 安装
function dea {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log dea -- 开始部部署dea组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh dea >/dev/null
    wait
    echo '在secure_path中添加ruby路径'
    add_path='Defaults  secure_path=\"/home/orchard/language/ruby19/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"'
    sudo sh -c 'echo $add_path >> /etc/sudoers'
    echo '开始修改配置文件dea.yml'
    cc_config=/home/orchard/dea/config/dea.yml
    echo '修改local_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'local_route=\$local_route'
    sed -i \"/local_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/nats_uri:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改domain'
    sed -i '/domain:/{s/:.*$/: $4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';

    echo '最后启动dea...'
    if [[ ! \$(ps -ef |grep -v grep| grep dea) ]]; then
        sudo sh -c '/etc/init.d/dea start >/dev/null'
    fi
    wait 
    echo '启动dea 完成'
    "
}

# 安装mysql_gateway组件
function mysql_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log mysql_gateway -- 开始安装mysql_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh mysql_gateway >/dev/null
    wait

    echo '开始编辑配置文件mysql_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/mysql_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '加入默认配额项'
    sed -i '/ default_quota:/a\\  mem_default_quota: 30\\n  disk_default_quota: 30' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep mysql_gateway) ]]; then
        sed -i '/components/{s/]/,\"mysql_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动mysql_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start mysql_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装mysql数据库
function install_mysql {
    if [[ $# != 2 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log install_mysql -- 开始安装mysql数据库"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/misc/mysql
    echo '修改my.cnf文件'
    cat my.cnf >/tmp/my.cnf
    sed -i '/bind_address/a\\skip-name-resolve\\nlower_case_table_names=1' /tmp/my.cnf 
    if [[ ! \$(ps aux |grep -v grep |grep mysqld) ]]; then
        sudo sh -c './install_mysql.sh >/dev/null'
    fi
    wait
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装mysql_node组件
function mysql_node {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip mysql_ip"
        exit 1
    fi
    echo "log mysql_node -- 开始安装mysql_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh mysql_node >/dev/null
    wait

    echo '开始编辑配置文件mysql_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/mysql_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改mysql数据库IP地址'
    sed -i '/mysql:/{n; s/:.*$/: $4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep mysql_node) ]]; then
        sed -i '/components/{s/]/,\"mysql_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动mysql_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start mysql_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装postgresql_gateway组件
function postgresql_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log postgresql_gateway -- 开始安装postgresql_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh postgresql_gateway >/dev/null
    wait

    echo '开始编辑配置文件postgresql_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/postgresql_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '加入默认配额项'
    if [[ ! \$(cat \$cc_config |grep disk_default_quota) ]]; then
        sed -i '/service:/a\\  default_quota: 25\\n  disk_default_quota: 128' \$cc_config
    fi
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep postgresql_gateway) ]]; then
        sed -i '/components/{s/]/,\"postgresql_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动postgresql_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start postgresql_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装postgresql数据库
function install_postgresql {
    if [[ $# != 2 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log install_postgresql -- 开始安装postgresql数据库"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/misc/postgresql

    if [[ ! \$(ps aux |grep -v grep |grep -w postgres) ]]; then
        echo 'log install_postgresql -- 开始安装postgresql数据库'
        cd /home/orchard/nfs/wingarden_install/misc/postgresql
        sudo sh -c './install_postgresql.sh >/dev/null'
        echo 'postgresql安装成功...'
    fi

    wait
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装postgresql_node组件
function postgresql_node {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip postgresql_ip"
        exit 1
    fi
    echo "log postgresql_node -- 开始安装postgresql_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh postgresql_node >/dev/null
    wait

    echo '开始编辑配置文件postgresql_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/postgresql_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改postgresql数据库IP地址'
    sed -i '/postgresql:/{n; s/:.*$/: $4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep postgresql_node) ]]; then
        sed -i '/components/{s/]/,\"postgresql_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动postgresql_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start postgresql_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装oracle_gateway组件
function oracle_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log oracle_gateway -- 开始安装oracle_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh oracle_gateway >/dev/null
    wait

    echo '开始编辑配置文件oracle_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/oracle_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '加入默认配额项'
    sed -i '/service:/a\\  default_quota: 25\\n  disk_default_quota: 128' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep oracle_gateway) ]]; then
        sed -i '/components/{s/]/,\"oracle_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动oracle_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start oracle_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装oracle数据库
function install_oracle {
    echo 'install oracle. todo...'
}

# 安装oracle_node组件
function oracle_node {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip oracle_ip"
        exit 1
    fi
    echo "log oracle_node -- 开始安装oracle_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh oracle_node >/dev/null
    wait

    echo '安装Oracle instant client'
    cd /home/orchard/nfs/wingarden_install/
    #sudo dpkg -ipkg/libaio1_0.3.109-2ubuntu1_amd64.deb
    #unzip misc/oracle/instantclient-basic-linux.x64-11.2.0.3.0.zip -d /home/orchard
    #unzip misc/oracle/instantclient-sdk-linux.x64-11.2.0.3.0.zip -d /home/orchard
    #sudo ln -s /home/orchard/instantclient_11_2/libclntsh.so.11.1 /usr/lib/libclntsh.so.11.1
    #sudo ln -s /home/orchard/instantclient_11_2/libnnz11.so /usr/lib/libnnz11.so

    echo '开始编辑配置文件oracle_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/oracle_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改oracle数据库IP地址'
    sed -i '/oracle:/{n; s/:.*$/: $4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep oracle_node) ]]; then
        sed -i '/components/{s/]/,\"oracle_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动oracle_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start oracle_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装memcached_gateway组件
function memcached_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log memcached_gateway -- 开始安装memcached_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh memcached_gateway >/dev/null
    wait

    echo '开始编辑配置文件memcached_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/memcached_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep memcached_gateway) ]]; then
        sed -i '/components/{s/]/,\"memcached_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动memcached_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start memcached_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装memcached服务
function install_memcached {
    if [[ $# != 2 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log install_memcached -- 开始安装memcached服务"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/misc/memcached
    echo 'log install_memcached -- 开始安装memcached'
    sudo sh -c './install_memcached.sh >/dev/null'
    echo 'memcached安装成功...'
    wait
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装memcached_node组件
function memcached_node {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log memcached_node -- 开始安装memcached_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh memcached_node >/dev/null
    wait

    echo '开始编辑配置文件memcached_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/memcached_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改memcached_server_path'
    sed -i '/memcached_server_path:/{s/:.*$/: \\/home\\/orchard\\/memcached\\/bin\\/memcached/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep memcached_node) ]]; then
        sed -i '/components/{s/]/,\"memcached_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动memcached_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start memcached_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装redis_gateway组件
function redis_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log redis_gateway -- 开始安装redis_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh redis_gateway >/dev/null
    wait

    echo '开始编辑配置文件redis_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/redis_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '增加默认配额'
    if [[ ! \$(cat \$cc_config |grep mem_default_quota) ]]; then
        sed -i '/current/a\\  mem_default_quota: 50'  \$cc_config
    fi
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep redis_gateway) ]]; then
        sed -i '/components/{s/]/,\"redis_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动redis_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start redis_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装redis服务
function install_redis {
    if [[ $# != 2 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log install_redis -- 开始安装redis服务"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/misc/redis
    echo 'log install_redis -- 开始安装redis'
    cd /home/orchard/nfs/wingarden_install/misc/redis
    sudo sh -c './install_redis.sh >/dev/null'
    echo 'redis安装成功...'
    wait
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装redis_node组件
function redis_node {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log redis_node -- 开始安装redis_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh redis_node >/dev/null
    wait

    echo '开始编辑配置文件redis_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/redis_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改redis_server_path'
    sed -i '/redis_server_path:/{n;s/:.*$/: \\\"\\/home\\/orchard\\/redis-2.6.12\\/src\\/redis-server\\\"/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep redis_node) ]]; then
        sed -i '/components/{s/]/,\"redis_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动redis_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start redis_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装mongodb_gateway组件
function mongodb_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log mongodb_gateway -- 开始安装mongodb_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh mongodb_gateway >/dev/null
    wait

    echo '开始编辑配置文件mongodb_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/mongodb_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep mongodb_gateway) ]]; then
        sed -i '/components/{s/]/,\"mongodb_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动mongodb_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start mongodb_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装mongodb服务
function install_mongodb {
    if [[ $# != 2 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log install_mongodb -- 开始安装mongodb服务"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/misc/mongodb
    echo 'log install_mongodb -- 开始安装mongodb'
    if [[ ! \$(ps aux |grep -v grep |grep -w mongod) ]]; then
        cd /home/orchard/nfs/wingarden_install/misc/mongodb
        sudo sh -c './install_mongodb.sh >/dev/null'
    fi
    echo 'mongodb安装成功...'
    wait
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装mongodb_node组件
function mongodb_node {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log mongodb_node -- 开始安装mongodb_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh mongodb_node >/dev/null
    wait

    echo '开始编辑配置文件mongodb_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/mongodb_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改mongod_path'
    sed -i '/mongod_path:/{n;s/:.*$/: \\\"\\/home\\/orchard\\/mongodb\\/bin\\/mongod\\\"/}' \$cc_config
    echo '修改mongorestore_path'
    sed -i '/mongorestore_path:/{n;s/:.*$/: \\\"\\/home\\/orchard\\/mongodb\\/bin\\/mongorestore\\\"/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep mongodb_node) ]]; then
        sed -i '/components/{s/]/,\"mongodb_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动mongodb_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start mongodb_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装rabbitmq_gateway组件
function rabbitmq_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log rabbitmq_gateway -- 开始安装rabbitmq_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh rabbitmq_gateway >/dev/null
    wait

    echo '开始编辑配置文件rabbitmq_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/rabbitmq_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改默认配额'
    sed -i '/version_aliases/{n;a\\  mem_default_quota: 128\\n  disk_default_quota: 128
    }' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep rabbitmq_gateway) ]]; then
        sed -i '/components/{s/]/,\"rabbitmq_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动rabbitmq_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start rabbitmq_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装rabbitmq服务
function install_rabbitmq {
    if [[ $# != 2 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip"
        exit 1
    fi
    echo "log install_rabbitmq -- 开始安装rabbitmq服务"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install/misc/rabbitmq
    echo 'log install_rabbitmq -- 开始安装rabbitmq'
    cd /home/orchard/nfs/wingarden_install/misc/rabbitmq
    sudo sh -c './install_rabbitmq.sh >/dev/null'
    echo 'erl加入path'
    if [[ ! \$(cat /etc/profile |grep erlang) ]]; then
        sudo sh -c 'echo \"/opt/erlang/otp_r15b02/bin:\$PATH\" >> /etc/profile' 
        source /etc/profile
    fi
    echo 'rabbitmq安装成功...'
    wait
    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装rabbitmq_node组件
function rabbitmq_node {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log rabbitmq_node -- 开始安装rabbitmq_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh rabbitmq_node >/dev/null
    wait

    echo '开始编辑配置文件rabbitmq_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/rabbitmq_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改rabbitmq_server'
    sed -i '/rabbitmq_server:/{s/:.*$/: \\/home\\/orchard\\/rabbitmq\\/2.8.7\\/sbin\\/rabbitmq-server/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep rabbitmq_node) ]]; then
        sed -i '/components/{s/]/,\"rabbitmq_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动rabbitmq_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start rabbitmq_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装cloud9_gateway组件
function cloud9_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log cloud9_gateway -- 开始安装cloud9_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh cloud9_gateway >/dev/null
    wait

    echo '开始编辑配置文件cloud9_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/cloud9_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '修改源码，加入cloud9和svn依赖'
    sed -i 's/oracle)/oracle cloud9 svn)/g' /home/orchard/cloudfoundry/vcap/dev_setup/lib/vcap_components.rb

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep cloud9_gateway) ]]; then
        sed -i '/components/{s/]/,\"cloud9_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动cloud9_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start cloud9_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装cloud9_node组件
function cloud9_node {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log cloud9_node -- 开始安装cloud9_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh cloud9_node >/dev/null
    wait

    echo '开始编辑配置文件cloud9_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/cloud9_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep cloud9_node) ]]; then
        sed -i '/components/{s/]/,\"cloud9_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动cloud9_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start cloud9_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装svn_gateway组件
function svn_gateway {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip domain_name"
        exit 1
    fi
    echo "log svn_gateway -- 开始安装svn_gateway组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh svn_gateway >/dev/null
    wait

    echo '开始编辑配置文件svn_gateway.yml'
    cc_config=/home/orchard/cloudfoundry/config/svn_gateway.yml
    echo '修改domain'
    sed -i '/cloud_controller_uri:/{s/: .*$/: http:\\/\\/api.$4/}' \$cc_config
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '修改svn_url'
    sed -i '/svn_url:/{s/:.*$/: svn.$4/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '修改源码，加入cloud9和svn依赖'
    sed -i 's/oracle)/oracle cloud9 svn)/g' /home/orchard/cloudfoundry/vcap/dev_setup/lib/vcap_components.rb

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep svn_gateway) ]]; then
        sed -i '/components/{s/]/,\"svn_gateway\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动svn_gateway'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev start svn_gateway
    wait
    echo '查看状态'
    /home/orchard/cloudfoundry/vcap/dev_setup/bin/vcap_dev status
    wait

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装svn_node组件
function svn_node {
    if [[ $# != 3 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip nats_ip"
        exit 1
    fi
    echo "log svn_node -- 开始安装svn_node组件"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh svn_node >/dev/null
    wait

    echo '安装svn依赖包'
    sudo aptitude install -y apache2 subversion libapache2-svn
    sudo a2enmod dav_svn
    sudo a2enmod authz_svn
    cd /etc/apache2
    sudo sed -i '/^Listen 80$/c\\Listen 8090' ports.conf
    sudo sed -i 's/80/8090/g' sites-available/default
    sudo sed -i '/export APACHE_RUN_USER/c\\export APACHE_RUN_USER=orchard' envvars
    sudo sed -i '/export APACHE_RUN_GROUP/c\\export APACHE_RUN_USER=orchard' envvars
    echo '复制svn对apache的配置文件'
    sudo cp ~/cloudfoundry/svnbase/config/dav_svn.conf mods-available/

    echo '开始编辑配置文件svn_node.yml'
    cc_config=/home/orchard/cloudfoundry/config/svn_node.yml
    echo '修改ip_route'
    local_route=\$(netstat -rn | grep -w -E '^0.0.0.0' | awk '{print \$2}')
    echo 'ip_route=\$local_route'
    sed -i \"/ip_route:/{s/: .*$/: \$local_route/}\" \$cc_config
    echo '修改nats的IP地址'
    sed -i '/mbus:/{s/@.*:/@$3:/}' \$cc_config
    echo '替换完成了。。。。。。。。。'

    echo '开始往vcap_components文件中加入'
    comp_file=/home/orchard/cloudfoundry/config/vcap_components.json
    if [[ ! \$(cat \$comp_file | grep svn_node) ]]; then
        sed -i '/components/{s/]/,\"svn_node\"]/}' \$comp_file
    fi
    echo 'ruby加入environment'
    if [[ ! \$(cat /etc/environment |grep ruby) ]]; then
        ruby_path=/home/orchard/language/ruby19/bin
        sudo sed -i \"s#.\\\$#:\${ruby_path}&#\" /etc/environment
    fi
    . /etc/environment
    echo '启动svn_node'
    cd /home/orchard/cloudfoundry/vcap/dev_setup/bin
    ./vcap_dev start svn_node
    echo '查看状态'
    ./vcap_dev status

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# 安装mango
function mango {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip sysdb_ip domain_name"
        exit 1
    fi
    echo "log mango -- 开始安装mango"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'
    cd /home/orchard/nfs/wingarden_install
    ./install.sh mango >/dev/null
    wait

    echo '开始编辑mango配置文件'
    cd /home/orchard/mango-1.5/properties
    echo '修改database.conf'
    sed -i '/^MDB_IP=/{s/=.*$/=$3/}' database.conf
    sed -i '/^TDB_IP=/{s/=.*$/=$3/}' database.conf
    echo '修改global.properties'
    sed -i '/^domain=/{s/=.*$/=$4/}' global.properties
    echo '替换完成了。。。。。。。。。'
    echo '启动mango的nginx之前，先检查下端口占用情况'
    ng_conf=/usr/local/nginx-1.4.2/conf/nginx15.conf
    echo '修改nginx15中的domain'
    sudo sed -i 's/wingarden.net/$domain_name/' \$ng_conf
    if [[ \$(sudo netstat -tnlp | grep -w 80) ]]; then
        echo '80端口已经被占用了, 改用8088端口，后面访问mango也用这个端口'
        sudo sed -i 's/ 80;/ 8088;/' \$ng_conf
    fi
    if [[ \$(sudo netstat -tnlp | grep -w 443) ]]; then
        echo 'https的443端口已经被占用了, 改用444端口'
        sudo sed -i 's/443;/444;/' \$ng_conf
    fi
    echo '如果有PID文件，先删之'
    if [[ -f /home/orchard/mango-1.5/RUNNING_PID ]]; then
        sudo rm -f /home/orchard/mango-1.5/RUNNING_PID
    fi
    echo '修改完成后，先启动nginx服务'
    sudo /etc/init.d/nginx15 start
    wait
    echo '然后启动mango服务'
    sudo /etc/init.d/mango15 start >/dev/null

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

# wingarden.net域名绑定
function bind_domain {
    if [[ $# != 4 ]]; then
        echo "请输入正确的IP地址参数: localhost_ip nfs_ip wingarden_ip domain_name"
        exit 1
    fi
    echo "log bind_domain -- 开始绑定域名ip"
    ssh -l orchard "$1" "
    echo '成功登录$1 ，现在开始挂载NFS服务器目录'
    echo '建立客户端的NFS挂载目录'
    if [[ ! -d '/home/orchard/nfs' ]]; then 
        mkdir /home/orchard/nfs
    else echo 'nfs目录存在无需再创建'
    fi
    sudo mount -t nfs $2:/home/public /home/orchard/nfs
    echo '挂载结果: $?'

    echo '开始编辑配置文件hosts'
    if [[ ! \$(cat /etc/hosts |grep $4) ]]; then
        sudo sed -i '\$ a $3 api.$4 uaa.$4' /etc/hosts
    fi

    cd ~
    echo '结束后卸载nfs';
    sudo umount -f -l /home/orchard/nfs;
    echo '卸载结果... $?';
    "
}

domain_name=$(python loadyml.py domain_name)
nfs_server_ip=$(python loadyml.py nfs_server)
sysdb_ip=$(python loadyml.py sysdb)
nats_ip=$(python loadyml.py nats)
router_ip=$(python loadyml.py router)
cloud_controller_ip=$(python loadyml.py cloud_controller)
uaa_ip=$(python loadyml.py uaa)
stager_ip=$(python loadyml.py stager)
health_manager_ip=$(python loadyml.py health_manager)
deas_ip=$(python loadyml.py deas)
mango_ip=$(python loadyml.py mango)
filesystem_gateway_ip=$(python loadyml.py filesystem_gateway)
mysql_gateway_ip=$(python loadyml.py mysql_gateway)
mysql_nodes_ip=$(python loadyml.py mysql_nodes)
postgresql_gateway_ip=$(python loadyml.py postgresql_gateway)
postgresql_nodes_ip=$(python loadyml.py postgresql_nodes)
oracle_gateway_ip=$(python loadyml.py oracle_gateway)
oracle_nodes_ip=$(python loadyml.py oracle_nodes)
memcached_gateway_ip=$(python loadyml.py memcached_gateway)
memcached_nodes_ip=$(python loadyml.py memcached_nodes)
redis_gateway_ip=$(python loadyml.py redis_gateway)
redis_nodes_ip=$(python loadyml.py redis_nodes)
mongodb_gateway_ip=$(python loadyml.py mongodb_gateway)
mongodb_nodes_ip=$(python loadyml.py mongodb_nodes)
rabbitmq_gateway_ip=$(python loadyml.py rabbitmq_gateway)
rabbitmq_nodes_ip=$(python loadyml.py rabbitmq_nodes)
cloud9_gateway_ip=$(python loadyml.py cloud9_gateway)
cloud9_nodes_ip=$(python loadyml.py cloud9_nodes)
svn_gateway_ip=$(python loadyml.py svn_gateway)
svn_nodes_ip=$(python loadyml.py svn_nodes)

echo $domain_name
echo $nfs_server_ip
echo $sysdb_ip
echo $svn_nodes_ip
echo $deas_ip

pwd_dir=$(pwd)
install_python
sysdb "$sysdb_ip" "$nfs_server_ip"
cd "$pwd_dir"
python after_install.py "$sysdb_ip" "5432" "root" "changeme" "$domain_name" 
nats "$nats_ip" "$nfs_server_ip"
gorouter "$router_ip" "$nfs_server_ip" "$nats_ip"
cloud_controller "$cloud_controller_ip" "$nfs_server_ip" "$nats_ip" "$sysdb_ip" "$domain_name"
uaa "$uaa_ip" "$nfs_server_ip" "$nats_ip" "$sysdb_ip" "$domain_name"
stager "$stager_ip" "$nfs_server_ip" "$nats_ip"
health_manager "$health_manager_ip" "$nfs_server_ip" "$nats_ip" "$sysdb_ip"
for deaipp in "$deas_ip"; do
    dea "$deaipp" "$nfs_server_ip" "$nats_ip" "$domain_name"
done
mysql_gateway "$mysql_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for mysqlnode_ip in "$mysql_nodes_ip"; do
    install_mysql "$mysqlnode_ip" "$nfs_server_ip"
    mysql_node "$mysqlnode_ip" "$nfs_server_ip" "$nats_ip" "$mysqlnode_ip"
done
postgresql_gateway "$postgresql_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for pg_ip in "$postgresql_nodes_ip"; do
    install_postgresql "$pg_ip" "$nfs_server_ip"
    postgresql_node "$pg_ip" "$nfs_server_ip" "$nats_ip" "$pg_ip"
done
oracle_gateway "$oracle_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for pg_ip in "$oracle_nodes_ip"; do
    install_oracle "$pg_ip" "$nfs_server_ip"
    oracle_node "$pg_ip" "$nfs_server_ip" "$nats_ip" "$pg_ip"
done
memcached_gateway "$memcached_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for mm_ip in "$memcached_nodes_ip"; do
    install_memcached "$mm_ip" "$nfs_server_ip"
    memcached_node "$mm_ip" "$nfs_server_ip" "$nats_ip"
done
redis_gateway "$redis_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for rd_ip in "$redis_nodes_ip"; do
    install_redis "$rd_ip" "$nfs_server_ip"
    redis_node "$rd_ip" "$nfs_server_ip" "$nats_ip"
done
mongodb_gateway "$mongodb_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for rd_ip in "$mongodb_nodes_ip"; do
    install_mongodb "$rd_ip" "$nfs_server_ip"
    mongodb_node "$rd_ip" "$nfs_server_ip" "$nats_ip"
done
rabbitmq_gateway "$rabbitmq_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for rd_ip in "$rabbitmq_nodes_ip"; do
    install_rabbitmq "$rd_ip" "$nfs_server_ip"
    rabbitmq_node "$rd_ip" "$nfs_server_ip" "$nats_ip"
done
cloud9_gateway "$cloud9_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for rd_ip in "$cloud9_nodes_ip"; do
    cloud9_node "$rd_ip" "$nfs_server_ip" "$nats_ip"
done
svn_gateway "$svn_gateway_ip" "$nfs_server_ip" "$nats_ip" "$domain_name"
for rd_ip in "$svn_nodes_ip"; do
    svn_node "$rd_ip" "$nfs_server_ip" "$nats_ip"
done
mango "$mango_ip" "$nfs_server_ip" "$sysdb_ip" "$domain_name"
bind_domain "$cloud_controller_ip" "$nfs_server_ip" "$cloud_controller_ip" "$domain_name"


exit 0
