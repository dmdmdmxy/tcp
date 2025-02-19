# 第一步：运行多个 Docker 容器
echo "开始运行多个 Docker 容器..."

# 运行第一个容器
docker run --restart=on-failure --name gw-basichk-01-02-03-04 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=42,66,57,3 \
-e user_tcp_limit=1000 \
-e user_speed_limit=100 \
-e forbidden_bit_torrent=true \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=80 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga

docker run --restart=on-failure --name gw-basichk-05-06-07-08 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=61,47,65,40 \
-e auto_out_ip=true \
-e proxy_protocol=true \
-e user_tcp_limit=1000 \
-e user_speed_limit=100 \
-e forbidden_bit_torrent=true \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=80 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga


docker run --restart=on-failure --name gw-basichk-09-10 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=55,54 \
-e auto_out_ip=true \
-e proxy_protocol=true \
-e user_tcp_limit=1000 \
-e user_speed_limit=100 \
-e forbidden_bit_torrent=true \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=80 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga

# 运行第二个容器

docker run --restart=on-failure --name gw-prohk-01-02-03-04 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=20,7,46,31 \
-e user_tcp_limit=1000 \
-e user_speed_limit=1000 \
-e forbidden_bit_torrent=true \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=80 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga

docker run --restart=on-failure --name gw-prohk-05-06-07-08 -d \
-v /etc/soga/:/etc/soga/ --network host \
-e soga_key=Ox2YKGI6WiUBNXr1ZD2Ev0Y3HrLbev9v \
-e type=sspanel-uim \
-e server_type=v2ray \
-e api=webapi \
-e webapi_url=https://qwertyuiopzxcvbnm.icu/ \
-e webapi_key=qwer123 \
-e node_id=8,71,53,70 \
-e user_tcp_limit=1000 \
-e user_speed_limit=1000 \
-e forbidden_bit_torrent=true \
-e dy_limit_enable=true \
-e dy_limit_trigger_time=30 \
-e dy_limit_trigger_speed=80 \
-e dy_limit_speed=50 \
-e dy_limit_time=600 \
-e dy_limit_duration=19:00-24:00,00:00-02:00 \
vaxilu/soga



echo -e "${Info}所有 Docker 容器已成功启动！"
