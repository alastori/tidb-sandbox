# AWS MySQL VM – Upstream for TiDB Cloud DM Statement/Mixed Repro

Spin up a small EC2 instance running MySQL in `STATEMENT` (or `MIXED`) binlog mode, reachable by TiDB Cloud DM for the multi-statement batch repro.

## Prereqs
- AWS CLI configured (`AWS_PROFILE`, `AWS_REGION`).
- Existing EC2 key pair (`KEY_NAME`).
- TiDB Cloud egress IPs list (CIDRs).
- Choose instance type: `t3.micro` (or `t4g.micro` if ARM is fine).
- AMI (example, us-east-1): Amazon Linux 2023 x86_64 `ami-0c101f26f147fa7fd` (update per region).

## Steps
Set names:
```bash
export SG_NAME=dm-mysql-repro-sg
export INSTANCE_NAME=dm-mysql-repro
export KEY_NAME=your-keypair
export AWS_REGION=us-east-1
export TIDCLOUD_EGRESS_IPS="x.x.x.x/32 y.y.y.y/32"  # replace
```

1) **Create security group (lock to TiDB Cloud + your IP)**
```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
aws ec2 create-security-group --group-name "$SG_NAME" --description "mysql for tidb cloud"
SG_ID=$(aws ec2 describe-security-groups --group-names "$SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$MY_IP"
for cidr in $TIDCLOUD_EGRESS_IPS; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --protocol tcp --port 3306 --cidr "$cidr"
done
```

2) **Launch instance**
```bash
aws ec2 run-instances \
  --image-id ami-0c101f26f147fa7fd \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]"
INSTANCE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=running" --query 'Reservations[0].Instances[0].InstanceId' --output text)
PUB_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
```

3) **Install and configure MySQL in STATEMENT mode**
```bash
ssh -o StrictHostKeyChecking=no ec2-user@$PUB_IP <<'EOF'
sudo dnf install -y mysql-server
sudo systemctl enable --now mysqld
sudo mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'MyPassw0rd!';"
sudo tee -a /etc/my.cnf <<'CNF'
[mysqld]
log-bin=mysql-bin
server-id=1
binlog_format=STATEMENT
binlog_row_image=FULL
gtid_mode=OFF
enforce_gtid_consistency=OFF
CNF
sudo systemctl restart mysqld
EOF
```
To switch to `MIXED`, change `binlog_format` before restart.

4) **Verify**
```bash
mysql -h $PUB_IP -P 3306 -uroot -pMyPassw0rd! -e "SHOW VARIABLES LIKE 'binlog_format';"
```

5) **Use in TiDB Cloud DM**
- Source config: host `$PUB_IP`, port `3306`, user `root`, password `MyPassw0rd!`.
- Binlog is already `STATEMENT` (or `MIXED`), so DM precheck will fail unless you set `ignoreCheckingItems` or change upstream format.

6) **Cleanup**
```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
aws ec2 delete-security-group --group-name "$SG_NAME"
```

## Notes
- Keep the security group restricted to TiDB Cloud egress IPs (and your IP). Don’t leave 3306 open to the world.
- If GTID is needed, set `gtid_mode=ON`, `enforce_gtid_consistency=ON`, and adjust TiDB Cloud task accordingly.
