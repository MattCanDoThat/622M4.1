#!/bin/bash
set -euo pipefail

# ----------------------------
# On my honor, as an Aggie, I have neither given nor received unauthorized assistance on this assignment.
# I further affirm that I have not and will not provide this code to any person, platform, or repository,
# without the express written permission of Dr. Gomillion.
# I understand that any violation of these standards will have serious repercussions.
# ----------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

touch /root/1-script-started

# ----------------------------
# Progress Logging (clean STEP banners + status lines only)
# ----------------------------

ProgressLog="/var/log/user-data-progress.log"
touch "$ProgressLog"
chmod 644 "$ProgressLog"

TotalSteps=8
CurrentStep=0

NextStep() {
  CurrentStep=$((CurrentStep+1))
  Percent=$((CurrentStep*100/TotalSteps))
  {
    echo ""
    echo "=================================================="
    echo "STEP $CurrentStep of $TotalSteps  [$Percent%]"
    echo "$1"
    echo "=================================================="
  } | tee -a "$ProgressLog"
}

LogStatus() {
  echo "Status: $1" | tee -a "$ProgressLog"
}

# ----------------------------
# SSH Watcher: smooth ASCII bar + STEP X/8 + label + spinner
# Usage after SSH: watchud
# Auto-exits at STEP 8 with countdown then hands off to galera-setup
# ----------------------------

cat > /usr/local/bin/watch-userdata-progress <<'EOF'
#!/bin/bash
set -u

ProgressLog="/var/log/user-data-progress.log"
TotalBarWidth=24
RefreshSeconds=0.5

if [ ! -f "$ProgressLog" ]; then
  echo "Progress log not found: $ProgressLog"
  exit 1
fi

# Colors only when output is a real terminal
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_CYAN=""
  C_YELLOW=""
  C_GREEN=""
  C_RED=""
fi

Cols=$(tput cols 2>/dev/null || echo 120)

DrawBar() {
  local Percent="$1"
  local Filled=$((Percent * TotalBarWidth / 100))
  local Empty=$((TotalBarWidth - Filled))

  printf "["
  if [ "$Filled" -gt 0 ]; then
    printf "%s" "${C_CYAN}"
    printf "%0.s#" $(seq 1 "$Filled")
    printf "%s" "${C_RESET}"
  fi
  if [ "$Empty" -gt 0 ]; then
    printf "%s" "${C_DIM}"
    printf "%0.s-" $(seq 1 "$Empty")
    printf "%s" "${C_RESET}"
  fi
  printf "] %s%%" "$Percent"
}

GetLatestStepLine() {
  grep -E "STEP [0-9]+ of [0-9]+  \[[0-9]+%\]" "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

GetLatestPercent() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/.*\[\([0-9]\+\)%\].*/\1/p'
  else
    echo "0"
  fi
}

GetLatestStepNumbers() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/STEP \([0-9]\+\) of \([0-9]\+\).*/\1 \2/p'
  else
    echo "0 0"
  fi
}

GetLatestLabel() {
  awk '/STEP [0-9]+ of [0-9]+  \[[0-9]+%\]/{getline; print}' "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

RenderLine() {
  local Percent="$1"
  local StepNow="$2"
  local StepTotal="$3"
  local Label="$4"
  local Frame="$5"

  local Bar StepText StepPlain
  Bar="$(DrawBar "$Percent")"

  if [ "${StepTotal:-0}" -gt 0 ]; then
    StepText="${C_GREEN}STEP ${StepNow}/${StepTotal}${C_RESET}"
    StepPlain="STEP ${StepNow}/${StepTotal}"
  else
    StepText=""
    StepPlain=""
  fi

  local FixedLen=$(( 9 + 30 + 2 + ${#StepPlain} + 2 + 1 + 4 ))
  local MaxLabel=$(( Cols - FixedLen ))
  [ "$MaxLabel" -lt 8 ] && MaxLabel=8
  local TruncLabel="${Label:0:$MaxLabel}"

  # \r\033[2K clears the entire current line before redrawing — prevents
  # ANSI-inflated line width from wrapping and leaving ghost fragments on right
  printf "\r\033[2K"
  printf "${C_BOLD}Deploying${C_RESET} %s  %s  ${C_YELLOW}%s${C_RESET}  %s" \
    "$Bar" "$StepText" "$TruncLabel" "$Frame"
}

echo ""
echo "${C_BOLD}Watching EC2 user-data progress${C_RESET} (Ctrl+C to stop)"
echo ""

# Show some context
tail -n 20 "$ProgressLog" 2>/dev/null || true

LastLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo 0)

TargetPercent="$(GetLatestPercent)"
ShownPercent="$TargetPercent"
read -r StepNow StepTotal <<<"$(GetLatestStepNumbers)"
CurrentLabel="$(GetLatestLabel)"
[ -z "${CurrentLabel:-}" ] && CurrentLabel="Starting..."

i=0
frames='|/-\'

while true; do
  CurrentLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo "$LastLineCount")

  # Only print STEP banner lines from newly appended log content.
  if [ "$CurrentLineCount" -gt "$LastLineCount" ]; then
    NewLines=$(sed -n "$((LastLineCount+1)),${CurrentLineCount}p" "$ProgressLog" 2>/dev/null || true)
    if echo "$NewLines" | grep -qE "^STEP [0-9]+ of [0-9]+"; then
      printf "\r%-*s\n" "$Cols" " "
      echo "$NewLines" | grep -E "^(={10,}|STEP [0-9]+ of [0-9]+)" || true
    fi
    LastLineCount="$CurrentLineCount"
  fi

  # Update targets from log
  NewTarget="$(GetLatestPercent)"
  [ -n "${NewTarget:-}" ] && TargetPercent="$NewTarget"

  read -r NewStepNow NewStepTotal <<<"$(GetLatestStepNumbers)"
  [ -n "${NewStepNow:-}" ] && StepNow="$NewStepNow"
  [ -n "${NewStepTotal:-}" ] && StepTotal="$NewStepTotal"

  NewLabel="$(GetLatestLabel)"
  [ -n "${NewLabel:-}" ] && CurrentLabel="$NewLabel"

  # Smooth-fill toward the target
  if [ "$ShownPercent" -lt "$TargetPercent" ]; then
    ShownPercent=$((ShownPercent+1))
  elif [ "$ShownPercent" -gt "$TargetPercent" ]; then
    ShownPercent="$TargetPercent"
  fi

  # Completion check — STEP 8 of 8
  if tail -n 50 "$ProgressLog" 2>/dev/null | grep -q "STEP 8 of 8"; then
    RenderLine 100 8 8 "$CurrentLabel" ""
    printf "\n\n${C_GREEN}  Bootstrap complete — node is ready for Galera setup.${C_RESET}\n"

    if [ ! -x /usr/local/bin/galera-setup ]; then
      printf "${C_RED}  galera-setup command not found. Run: sudo galera-setup${C_RESET}\n"
      exit 0
    fi

    printf "\n  ${C_BOLD}Launching Galera Setup wizard in...${C_RESET}\n"
    for count in 5 4 3 2 1; do
      printf "\r    ${C_CYAN}%s${C_RESET} second(s)  (Ctrl+C to skip)  " "$count"
      sleep 1
    done
    printf "\r%-*s\n" "$Cols" " "

    exec sudo /usr/local/bin/galera-setup
  fi

  frame="${frames:i%4:1}"
  RenderLine "$ShownPercent" "$StepNow" "$StepTotal" "$CurrentLabel" "$frame"

  i=$((i+1))
  sleep "$RefreshSeconds"
done
EOF

chmod 755 /usr/local/bin/watch-userdata-progress

# ----------------------------
# Create watchud alias command
# ----------------------------

cat > /usr/local/bin/watchud <<'EOF'
#!/bin/bash
exec /usr/local/bin/watch-userdata-progress
EOF
chmod 755 /usr/local/bin/watchud

# Add watchud alias to ubuntu user's .bashrc for convenience
if [ -f /home/ubuntu/.bashrc ] && ! grep -q "alias watchud=" /home/ubuntu/.bashrc 2>/dev/null; then
  echo "" >> /home/ubuntu/.bashrc
  echo "alias watchud='/usr/local/bin/watchud'" >> /home/ubuntu/.bashrc
fi
chown ubuntu:ubuntu /home/ubuntu/.bashrc 2>/dev/null || true

# ----------------------------
# STEP 1: System prep
# ----------------------------

NextStep "System preparation and package updates"
LogStatus "Updating packages (apt update/upgrade)"
apt update
apt upgrade -y
LogStatus "Installing prerequisites (curl, unzip, wget)"
apt install apt-transport-https curl unzip wget -y
LogStatus "Prerequisites installed"

# ----------------------------
# STEP 2: Install MariaDB 11.8 + Galera
# ----------------------------

NextStep "Installing MariaDB 11.8 with Galera"
LogStatus "Adding MariaDB repo key and sources"
mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'

cat > /etc/apt/sources.list.d/mariadb.sources <<'EOF'
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.accretive-networks.net/mariadb/repo/11.8/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF

LogStatus "Installing MariaDB server and Galera"
apt update
apt install mariadb-server mariadb-plugin-provider-lz4 galera-4 -y

LogStatus "Starting MariaDB temporarily (for initial setup)"
systemctl start mariadb

# CRITICAL: Disable auto-start — Galera nodes must be started manually
# in the correct order. Auto-start on reboot causes split-brain / quorum loss.
LogStatus "Disabling MariaDB auto-start (required for Galera boot order control)"
systemctl disable mariadb

systemctl is-active --quiet mariadb || { echo "ERROR: MariaDB did not start"; exit 1; }
LogStatus "MariaDB running (temporarily). Auto-start disabled."
touch /root/3-mariadb-installed

# ----------------------------
# STEP 3: Write Galera config with placeholder IPs
# The galera-setup wizard will replace these with real IPs at runtime.
# ----------------------------

NextStep "Writing Galera configuration template"
LogStatus "Creating /etc/mysql/mariadb.conf.d/60-galera.cnf"

cat > /etc/mysql/mariadb.conf.d/60-galera.cnf <<'GALERAEOF'
# -----------------------------------------------------------
# Galera Cluster Configuration — FurnitureCluster
# Managed by galera-setup wizard. Do not edit IPs manually.
# -----------------------------------------------------------
[mysqld]

# Allow connections from any interface
bind-address            = 0.0.0.0

# Galera requires ROW-based binary logging
binlog_format           = ROW

# InnoDB is required for Galera (MVCC / row-level locking)
default_storage_engine  = InnoDB

# Required for Galera: avoids deadlocks on auto-increment across nodes
innodb_autoinc_lock_mode = 2

# Allow trigger/function creation with binary logging enabled
log_bin_trust_function_creators = 1

# ------- Galera Provider -------
wsrep_on               = ON
wsrep_provider         = /usr/lib/galera/libgalera_smm.so

# ------- Cluster Identity -------
wsrep_cluster_name     = "FurnitureCluster"

# PLACEHOLDER — replaced by galera-setup wizard
wsrep_cluster_address  = "gcomm://NODE_A_IP,NODE_B_IP,NODE_C_IP"

# PLACEHOLDER — replaced by galera-setup wizard
wsrep_node_address     = "THIS_NODE_IP"

# PLACEHOLDER — replaced by galera-setup wizard
wsrep_node_name        = "THIS_NODE_NAME"

# ------- SST Method -------
# rsync is simple and requires no extra credentials for State Snapshot Transfer
wsrep_sst_method       = rsync
GALERAEOF

LogStatus "60-galera.cnf written with placeholder IPs"

# ----------------------------
# STEP 4: Create Linux user mbennett
# ----------------------------

NextStep "Creating unprivileged Linux user (mbennett)"
LogStatus "Creating Linux user (mbennett)"
if id "mbennett" &>/dev/null; then
  echo "Linux user mbennett already exists"
else
  useradd -m -s /bin/bash "mbennett"
  echo "Created Linux user mbennett"
fi
LogStatus "Linux user step completed"

# ----------------------------
# STEP 5: Download and unzip data
# ----------------------------

NextStep "Downloading and unzipping source data"
LogStatus "Downloading dataset zip"
sudo -u "mbennett" wget -O "/home/mbennett/313007119.zip" "https://622.gomillion.org/data/313007119.zip"

if [ ! -s "/home/mbennett/313007119.zip" ]; then
  echo "ERROR: Download failed or zip is empty"
  exit 1
fi

LogStatus "Unzipping dataset"
sudo -u "mbennett" unzip -o "/home/mbennett/313007119.zip" -d "/home/mbennett"

for f in customers.csv orders.csv orderlines.csv products.csv; do
  [ ! -f "/home/mbennett/$f" ] && echo "ERROR: Missing $f after unzip" && exit 1
done
LogStatus "Dataset downloaded and verified"

# ----------------------------
# STEP 6: Generate etl.sql
# ----------------------------

NextStep "Generating etl.sql"
LogStatus "Writing etl.sql to disk"

cat > "/home/mbennett/etl.sql" <<'ETLEOF'
DROP DATABASE IF EXISTS POS;
CREATE DATABASE POS;
USE POS;

CREATE TABLE City
(
  zip   DECIMAL(5) ZEROFILL NOT NULL,
  city  VARCHAR(32)         NOT NULL,
  state VARCHAR(4)          NOT NULL,
  PRIMARY KEY (zip)
) ENGINE=InnoDB;

CREATE TABLE Customer
(
  id        SERIAL       NOT NULL,
  firstName VARCHAR(32)  NOT NULL,
  lastName  VARCHAR(30)  NOT NULL,
  email     VARCHAR(128) NULL,
  address1  VARCHAR(100) NULL,
  address2  VARCHAR(50)  NULL,
  phone     VARCHAR(32)  NULL,
  birthdate DATE         NULL,
  zip       DECIMAL(5) ZEROFILL NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_customer_city
    FOREIGN KEY (zip) REFERENCES City(zip)
) ENGINE=InnoDB;

CREATE TABLE Product
(
  id                SERIAL         NOT NULL,
  name              VARCHAR(128)   NOT NULL,
  currentPrice      DECIMAL(6,2)   NOT NULL,
  availableQuantity INT            NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE `Order`
(
  id          SERIAL       NOT NULL,
  datePlaced  DATE         NULL,
  dateShipped DATE         NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_order_customer
    FOREIGN KEY (customer_id) REFERENCES Customer(id)
) ENGINE=InnoDB;

CREATE TABLE Orderline
(
  order_id   BIGINT UNSIGNED NOT NULL,
  product_id BIGINT UNSIGNED NOT NULL,
  quantity   INT             NOT NULL,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_orderline_order
    FOREIGN KEY (order_id) REFERENCES `Order`(id),
  CONSTRAINT fk_orderline_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE PriceHistory
(
  id         SERIAL       NOT NULL,
  oldPrice   DECIMAL(6,2) NULL,
  newPrice   DECIMAL(6,2) NOT NULL,
  ts         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  product_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_pricehistory_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE staging_customer
(
  ID VARCHAR(50), FN VARCHAR(255), LN VARCHAR(255),
  CT VARCHAR(255), ST VARCHAR(255), ZP VARCHAR(50),
  S1 VARCHAR(255), S2 VARCHAR(255), EM VARCHAR(255), BD VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orders
(
  OID VARCHAR(50), CID VARCHAR(50), Ordered VARCHAR(50), Shipped VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orderlines
(
  OID VARCHAR(50), PID VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_products
(
  ID VARCHAR(50), Name VARCHAR(255), Price VARCHAR(50), Quantity_on_Hand VARCHAR(50)
) ENGINE=InnoDB;

LOAD DATA LOCAL INFILE '/home/mbennett/customers.csv'
INTO TABLE staging_customer
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orders.csv'
INTO TABLE staging_orders
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orderlines.csv'
INTO TABLE staging_orderlines
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/products.csv'
INTO TABLE staging_products
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@ID, @Name, @Price, @QOH)
SET ID=@ID, Name=@Name, Price=@Price, Quantity_on_Hand=@QOH;

INSERT INTO City (zip, city, state)
SELECT DISTINCT
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED),
  CT, ST
FROM staging_customer
WHERE NULLIF(ZP,'') IS NOT NULL;

INSERT INTO Customer (id, firstName, lastName, email, address1, address2, phone, birthdate, zip)
SELECT
  CAST(ID AS UNSIGNED), FN, LN, NULLIF(EM,''), NULLIF(S1,''), NULLIF(S2,''),
  NULL, STR_TO_DATE(NULLIF(BD,''), '%m/%d/%Y'),
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED)
FROM staging_customer;

INSERT INTO Product (id, name, currentPrice, availableQuantity)
SELECT
  CAST(ID AS UNSIGNED), Name,
  CAST(REPLACE(REPLACE(NULLIF(Price,''), '$', ''), ',', '') AS DECIMAL(6,2)),
  CAST(NULLIF(Quantity_on_Hand,'') AS UNSIGNED)
FROM staging_products;

INSERT INTO `Order` (id, datePlaced, dateShipped, customer_id)
SELECT
  CAST(OID AS UNSIGNED),
  CASE WHEN NULLIF(Ordered,'') IS NULL OR LOWER(Ordered)='cancelled' THEN NULL
       ELSE DATE(STR_TO_DATE(Ordered, '%Y-%m-%d %H:%i:%s')) END,
  CASE WHEN NULLIF(Shipped,'') IS NULL OR LOWER(Shipped)='cancelled' THEN NULL
       ELSE DATE(STR_TO_DATE(Shipped, '%Y-%m-%d %H:%i:%s')) END,
  CAST(CID AS UNSIGNED)
FROM staging_orders;

INSERT INTO Orderline (order_id, product_id, quantity)
SELECT CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED), COUNT(*)
FROM staging_orderlines
GROUP BY CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED);

INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
SELECT NULL, currentPrice, id FROM Product;

DROP TABLE staging_customer;
DROP TABLE staging_orders;
DROP TABLE staging_orderlines;
DROP TABLE staging_products;
ETLEOF

chown "mbennett:mbennett" "/home/mbennett/etl.sql"
LogStatus "etl.sql generated"

# ----------------------------
# STEP 7: Generate views.sql and triggers.sql
# NOTE: DELIMITER is a client-only directive — triggers use single-statement
# form (no BEGIN...END) so they work correctly via stdin redirection.
# ----------------------------

NextStep "Generating views.sql and triggers.sql"
LogStatus "Writing views.sql to disk"

cat > "/home/mbennett/views.sql" <<'VIEWEOF'
USE POS;

DROP VIEW IF EXISTS v_ProductBuyers;

CREATE VIEW v_ProductBuyers AS
SELECT
    p.id AS productID,
    p.name AS productName,
    IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id
            SEPARATOR ', '
        ),
        ''
    ) AS customers
FROM Product p
LEFT JOIN Orderline ol ON p.id = ol.product_id
LEFT JOIN `Order` o ON ol.order_id = o.id
LEFT JOIN Customer c ON o.customer_id = c.id
GROUP BY p.id, p.name
ORDER BY p.id;

DROP TABLE IF EXISTS mv_ProductBuyers;

CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

CREATE INDEX idx_mv_productID ON mv_ProductBuyers(productID);
VIEWEOF

chown "mbennett:mbennett" "/home/mbennett/views.sql"
LogStatus "views.sql generated"

LogStatus "Writing triggers.sql to disk"

cat > "/home/mbennett/triggers.sql" <<'TRIGEOF'
USE POS;

DROP TRIGGER IF EXISTS trg_orderline_insert;
DROP TRIGGER IF EXISTS trg_orderline_delete;
DROP TRIGGER IF EXISTS trg_product_price_update;

CREATE TRIGGER trg_orderline_insert
AFTER INSERT ON Orderline
FOR EACH ROW
UPDATE mv_ProductBuyers
SET customers = (
    SELECT IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id SEPARATOR ', '
        ), '')
    FROM Orderline ol
    JOIN `Order` o ON ol.order_id = o.id
    JOIN Customer c ON o.customer_id = c.id
    WHERE ol.product_id = NEW.product_id
)
WHERE productID = NEW.product_id;

CREATE TRIGGER trg_orderline_delete
AFTER DELETE ON Orderline
FOR EACH ROW
UPDATE mv_ProductBuyers
SET customers = (
    SELECT IFNULL(
        GROUP_CONCAT(
            DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
            ORDER BY c.id SEPARATOR ', '
        ), '')
    FROM Orderline ol
    JOIN `Order` o ON ol.order_id = o.id
    JOIN Customer c ON o.customer_id = c.id
    WHERE ol.product_id = OLD.product_id
)
WHERE productID = OLD.product_id;

CREATE TRIGGER trg_product_price_update
AFTER UPDATE ON Product
FOR EACH ROW
INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
SELECT OLD.currentPrice, NEW.currentPrice, NEW.id
WHERE OLD.currentPrice <> NEW.currentPrice;
TRIGEOF

chown "mbennett:mbennett" "/home/mbennett/triggers.sql"
LogStatus "triggers.sql generated"

# ----------------------------
# STEP 8: Install galera-setup wizard as standalone command
# This single wizard handles both Node A (bootstrap) and Nodes B/C (join).
# Run manually after watchud completes: sudo galera-setup
# ----------------------------

NextStep "Installing Galera Setup wizard"

cat > /usr/local/bin/galera-setup <<'WIZEOF'
#!/bin/bash
# =============================================================================
# GALERA CLUSTER — Setup Wizard
# Handles Node A (bootstrap) and Nodes B/C (join) from a single script.
# Run after User Data completes: sudo galera-setup
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Please run as root: sudo galera-setup"
  exit 1
fi

set +e

DbPass="MyVoiceIsMyPassport!"
GaleraCnf="/etc/mysql/mariadb.conf.d/60-galera.cnf"

# Colors
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_CYAN=$'\033[36m'
C_DIM=$'\033[2m'

ValidateIP() {
  # Returns 0 (true) if argument looks like a valid IPv4 address
  echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

PromptIP() {
  local Label="$1"
  local Default="$2"
  local Result=""
  while true; do
    if [ -n "$Default" ]; then
      read -rp "  ${Label} [${Default}]: " Result
      [ -z "$Result" ] && Result="$Default"
    else
      read -rp "  ${Label}: " Result
    fi
    if ValidateIP "$Result"; then
      echo "$Result"
      return 0
    fi
    printf "  ${C_RED}Invalid IP format. Try again.${C_RESET}\n"
  done
}

# ----------------------------
# Screen 1: Welcome + Node Identity
# ----------------------------
clear
echo ""
printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}║        GALERA CLUSTER — Setup Wizard                         ║${C_RESET}\n"
printf "${C_BOLD}║        FurnitureCluster (3-Node Multi-Master)                ║${C_RESET}\n"
printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
echo ""
printf "  This wizard will configure this node's Galera settings and\n"
printf "  either bootstrap the cluster (Node A) or join it (Nodes B/C).\n"
echo ""
printf "  ${C_YELLOW}Have all 3 EC2 instances finished their User Data scripts${C_RESET}\n"
printf "  ${C_YELLOW}before proceeding on Node A.${C_RESET}\n"
echo ""
read -rp "  Press Enter to begin..." _

# ----------------------------
# Screen 2: Collect all 3 IPs + this node's identity
# ----------------------------
clear
echo ""
printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}║        Step 1 of 4 — Node Identity & IP Configuration        ║${C_RESET}\n"
printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
echo ""

DetectedIP=$(hostname -I | awk '{print $1}')
printf "  ${C_DIM}Detected private IP of this node:${C_RESET} ${C_CYAN}%s${C_RESET}\n" "$DetectedIP"
echo ""

printf "  Enter the ${C_BOLD}private IP${C_RESET} for each node.\n"
printf "  ${C_DIM}(Find these in your EC2 console under 'Private IPv4 address')${C_RESET}\n"
echo ""

NODE_A_IP=$(PromptIP "Node A IP" "")
NODE_B_IP=$(PromptIP "Node B IP" "")
NODE_C_IP=$(PromptIP "Node C IP" "")

echo ""
printf "  Which node is ${C_BOLD}this${C_RESET} server?\n"
printf "  ${C_CYAN}[A]${C_RESET}  Node A ${C_DIM}(bootstrap — start this one first)${C_RESET}\n"
printf "  ${C_CYAN}[B]${C_RESET}  Node B ${C_DIM}(join after Node A is up)${C_RESET}\n"
printf "  ${C_CYAN}[C]${C_RESET}  Node C ${C_DIM}(join after Nodes A and B are up)${C_RESET}\n"
echo ""

NodeRole=""
while true; do
  read -rp "  This node is [A/B/C]: " NodeRole
  NodeRole=$(echo "$NodeRole" | tr '[:lower:]' '[:upper:]')
  case "$NodeRole" in
    A) ThisNodeIP="$NODE_A_IP"; ThisNodeName="NodeA"; break ;;
    B) ThisNodeIP="$NODE_B_IP"; ThisNodeName="NodeB"; break ;;
    C) ThisNodeIP="$NODE_C_IP"; ThisNodeName="NodeC"; break ;;
    *) printf "  ${C_RED}Please enter A, B, or C.${C_RESET}\n" ;;
  esac
done

echo ""
printf "  ${C_GREEN}Configuration summary:${C_RESET}\n"
printf "    Node A: %s\n" "$NODE_A_IP"
printf "    Node B: %s\n" "$NODE_B_IP"
printf "    Node C: %s\n" "$NODE_C_IP"
printf "    ${C_BOLD}This node: %s (%s)${C_RESET}\n" "$ThisNodeName" "$ThisNodeIP"
echo ""
read -rp "  Correct? Press Enter to continue or Ctrl+C to restart..." _

# ----------------------------
# Screen 3: Write Galera config
# ----------------------------
clear
echo ""
printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}║        Step 2 of 4 — Writing Galera Configuration            ║${C_RESET}\n"
printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
echo ""

printf "  Updating %s...\n" "$GaleraCnf"

# Replace placeholder IPs with real values
sed -i "s|NODE_A_IP,NODE_B_IP,NODE_C_IP|${NODE_A_IP},${NODE_B_IP},${NODE_C_IP}|g" "$GaleraCnf"
sed -i "s|THIS_NODE_IP|${ThisNodeIP}|g"   "$GaleraCnf"
sed -i "s|THIS_NODE_NAME|${ThisNodeName}|g" "$GaleraCnf"

if [ $? -eq 0 ]; then
  printf "  ${C_GREEN}✓ 60-galera.cnf updated successfully.${C_RESET}\n"
else
  printf "  ${C_RED}ERROR: Failed to update config. Check $GaleraCnf manually.${C_RESET}\n"
  read -rp "  Press Enter to continue anyway..." _
fi

echo ""
printf "  ${C_DIM}Current wsrep settings:${C_RESET}\n"
grep -E "^wsrep_" "$GaleraCnf" | sed 's/^/    /'
echo ""

# Stop MariaDB before cluster start/join
printf "  Stopping MariaDB service...\n"
systemctl stop mariadb 2>/dev/null || true
sleep 2
printf "  ${C_GREEN}✓ MariaDB stopped.${C_RESET}\n"
echo ""
read -rp "  Press Enter to continue to cluster start..." _

# ----------------------------
# Screen 4: Bootstrap or Join
# ----------------------------
clear
echo ""

if [ "$NodeRole" = "A" ]; then
  printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_BOLD}║        Step 3 of 4 — Bootstrapping the Cluster (Node A)      ║${C_RESET}\n"
  printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
  echo ""
  printf "  ${C_YELLOW}Node A must bootstrap the cluster before B and C can join.${C_RESET}\n"
  printf "  This command starts MariaDB as the founding node of a new cluster.\n"
  echo ""
  read -rp "  Press Enter to run galera_new_cluster now..." _
  echo ""

  printf "  Running galera_new_cluster...\n"
  galera_new_cluster
  GaleraExit=$?

  if [ $GaleraExit -eq 0 ]; then
    printf "  ${C_GREEN}✓ galera_new_cluster succeeded.${C_RESET}\n"
  else
    printf "  ${C_RED}ERROR: galera_new_cluster failed (exit $GaleraExit).${C_RESET}\n"
    printf "  ${C_DIM}Check: sudo tail -50 /var/log/mysql/error.log${C_RESET}\n"
    read -rp "  Press Enter to continue..." _
  fi

  echo ""
  printf "  Verifying cluster size (should be 1)...\n"
  sleep 2
  ClusterSize=$(mariadb -sNe "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}')
  if [ "${ClusterSize:-0}" -eq 1 ]; then
    printf "  ${C_GREEN}✓ wsrep_cluster_size = 1. Node A is the founding node.${C_RESET}\n"
  else
    printf "  ${C_RED}  wsrep_cluster_size = ${ClusterSize:-unknown}. Expected 1.${C_RESET}\n"
    printf "  ${C_DIM}  Check error log: sudo tail -50 /var/log/mysql/error.log${C_RESET}\n"
  fi

  echo ""
  read -rp "  Press Enter to continue to final setup (Step 4)..." _

else
  # Node B or C — join existing cluster
  printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
  printf "${C_BOLD}║        Step 3 of 4 — Joining the Cluster (%s)             ║${C_RESET}\n" "Node${NodeRole}"
  printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
  echo ""

  if [ "$NodeRole" = "B" ]; then
    printf "  ${C_YELLOW}Ensure Node A has been bootstrapped and is running before joining.${C_RESET}\n"
    ExpectedSize=2
  else
    printf "  ${C_YELLOW}Ensure Nodes A and B are both running before joining.${C_RESET}\n"
    ExpectedSize=3
  fi

  echo ""
  read -rp "  Press Enter to start MariaDB and join the cluster..." _
  echo ""

  printf "  Starting MariaDB (joining cluster)...\n"
  systemctl start mariadb
  StartExit=$?

  if [ $StartExit -eq 0 ]; then
    printf "  ${C_GREEN}✓ MariaDB started.${C_RESET}\n"
  else
    printf "  ${C_RED}ERROR: MariaDB failed to start (exit $StartExit).${C_RESET}\n"
    printf "  ${C_DIM}Check: sudo tail -50 /var/log/mysql/error.log${C_RESET}\n"
    read -rp "  Press Enter to continue..." _
  fi

  echo ""
  printf "  Verifying cluster size (should be %s)...\n" "$ExpectedSize"
  sleep 3
  ClusterSize=$(mariadb -sNe "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}')
  if [ "${ClusterSize:-0}" -eq "$ExpectedSize" ]; then
    printf "  ${C_GREEN}✓ wsrep_cluster_size = %s. %s has joined successfully.${C_RESET}\n" "$ExpectedSize" "Node${NodeRole}"
  else
    printf "  ${C_RED}  wsrep_cluster_size = ${ClusterSize:-unknown}. Expected %s.${C_RESET}\n" "$ExpectedSize"
    printf "  ${C_DIM}  Possible causes: Galera ports blocked, Node A not running,${C_RESET}\n"
    printf "  ${C_DIM}  or config IP mismatch. Check: sudo tail -50 /var/log/mysql/error.log${C_RESET}\n"
  fi

  echo ""
  read -rp "  Press Enter to continue to final setup (Step 4)..." _
fi

# ----------------------------
# Screen 5: Final setup (Node A only — runs ETL + views + creates DB user)
#           Nodes B/C get a summary screen instead
# ----------------------------
clear
echo ""
printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
printf "${C_BOLD}║        Step 4 of 4 — Database Load & User Setup              ║${C_RESET}\n"
printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
echo ""

if [ "$NodeRole" = "A" ]; then
  printf "  ${C_YELLOW}Run this step ONLY after all 3 nodes are in the cluster.${C_RESET}\n"
  printf "  ${C_DIM}(wsrep_cluster_size must be 3 before loading data)${C_RESET}\n"
  echo ""
  printf "  Verify cluster size now:\n"
  ClusterSize=$(mariadb -sNe "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}')
  printf "    wsrep_cluster_size = ${C_CYAN}%s${C_RESET}\n" "${ClusterSize:-unknown}"
  echo ""

  if [ "${ClusterSize:-0}" -ne 3 ]; then
    printf "  ${C_RED}WARNING: Cluster size is not 3. It is strongly recommended${C_RESET}\n"
    printf "  ${C_RED}that you wait for all nodes to join before loading data.${C_RESET}\n"
    echo ""
    read -rp "  Proceed anyway? (y/N): " ForceLoad
    if [ "$ForceLoad" != "y" ] && [ "$ForceLoad" != "Y" ]; then
      printf "\n  ${C_DIM}Exiting. Re-run 'sudo galera-setup' once all nodes are up.${C_RESET}\n\n"
      exit 0
    fi
  fi

  # Sub-menu for Node A final steps
  sA=0; sB=0; sC=0

  CheckMark() { [ "$1" -eq 1 ] && printf "${C_GREEN}✓${C_RESET}" || printf "${C_DIM}·${C_RESET}"; }

  DrawFinalMenu() {
    clear
    echo ""
    printf "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}\n"
    printf "${C_BOLD}║        Node A — Final Database Setup                         ║${C_RESET}\n"
    printf "${C_BOLD}║        Cluster size: %-39s ║${C_RESET}\n" "$(mariadb -sNe "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}') nodes"
    printf "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}\n"
    echo ""
    printf "  ${C_CYAN}[1]${C_RESET} $(CheckMark $sA)  ${C_YELLOW}Run etl.sql${C_RESET} ${C_DIM}(builds POS database — replicates to B & C)${C_RESET}\n"
    printf "  ${C_CYAN}[2]${C_RESET} $(CheckMark $sB)  Create mbennett DB user + grant privileges ${C_DIM}(requires step 1)${C_RESET}\n"
    printf "  ${C_CYAN}[3]${C_RESET} $(CheckMark $sC)  ${C_YELLOW}Run views.sql + triggers.sql${C_RESET} ${C_DIM}(requires step 2)${C_RESET}\n"
    echo ""
    printf "  ${C_CYAN}[r]${C_RESET}    Refresh menu / re-check cluster size\n"
    printf "  ${C_CYAN}[q]${C_RESET}    Quit (return to prompt)\n"
    echo ""
  }

  while true; do
    DrawFinalMenu
    read -rp "  Select step: " choice

    case "$choice" in

      1)
        echo ""
        printf "${C_BOLD}Running etl.sql (this will take a moment)...${C_RESET}\n"
        printf "${C_DIM}Data loads on Node A and replicates synchronously to B and C.${C_RESET}\n"
        echo ""
        mariadb --local-infile=1 < /home/mbennett/etl.sql
        if [ $? -eq 0 ]; then
          printf "${C_GREEN}  ✓ ETL complete. POS database built and replicated.${C_RESET}\n"
          sA=1
        else
          printf "${C_RED}  ERROR: ETL failed. Check /var/log/user-data.log${C_RESET}\n"
        fi
        read -rp "  Press Enter to continue..." _
        ;;

      2)
        echo ""
        if [ $sA -ne 1 ]; then
          printf "${C_RED}  BLOCKED: Run etl.sql first (step 1) — POS database must exist.${C_RESET}\n"
        else
          printf "${C_BOLD}Creating mbennett MariaDB user...${C_RESET}\n"
          mariadb <<SQL
CREATE USER IF NOT EXISTS 'mbennett'@'localhost' IDENTIFIED BY '${DbPass}';
GRANT ALL PRIVILEGES ON POS.* TO 'mbennett'@'localhost';
FLUSH PRIVILEGES;
SQL
          if [ $? -eq 0 ]; then
            printf "${C_GREEN}  ✓ mbennett created with POS.* privileges.${C_RESET}\n"
            printf "${C_DIM}  Note: this localhost user does not replicate — create on each node if needed.${C_RESET}\n"
            sB=1
          else
            printf "${C_RED}  ERROR: Failed to create DB user.${C_RESET}\n"
          fi
        fi
        read -rp "  Press Enter to continue..." _
        ;;

      3)
        echo ""
        if [ $sB -ne 1 ]; then
          printf "${C_RED}  BLOCKED: Complete step 2 first.${C_RESET}\n"
        else
          printf "${C_BOLD}Running views.sql...${C_RESET}\n"
          mariadb < /home/mbennett/views.sql
          if [ $? -eq 0 ]; then
            printf "${C_GREEN}  ✓ views.sql complete (view + materialized view + index).${C_RESET}\n"
          else
            printf "${C_RED}  ERROR: views.sql failed.${C_RESET}\n"
          fi

          echo ""
          printf "${C_BOLD}Running triggers.sql...${C_RESET}\n"
          mariadb < /home/mbennett/triggers.sql
          if [ $? -eq 0 ]; then
            printf "${C_GREEN}  ✓ triggers.sql complete (3 triggers created).${C_RESET}\n"
            sC=1
          else
            printf "${C_RED}  ERROR: triggers.sql failed.${C_RESET}\n"
          fi

          if [ $sC -eq 1 ]; then
            echo ""
            printf "${C_BOLD}${C_GREEN}"
            printf "  ╔══════════════════════════════════════════════════════════╗\n"
            printf "  ║   All setup steps complete. FurnitureCluster is live.    ║\n"
            printf "  ║   All 3 nodes are multi-master and accepting writes.     ║\n"
            printf "  ║   Run: mariadb -u mbennett -p                            ║\n"
            printf "  ║   Then: USE POS; SHOW TABLES;                            ║\n"
            printf "  ╚══════════════════════════════════════════════════════════╝\n"
            printf "${C_RESET}"
          fi
        fi
        read -rp "  Press Enter to continue..." _
        ;;

      r|R) ;;

      q|Q)
        echo ""
        printf "${C_DIM}  Exiting wizard. Run 'sudo galera-setup' to re-launch at any time.${C_RESET}\n\n"
        exit 0
        ;;

      *)
        printf "${C_RED}  Invalid selection.${C_RESET}\n"
        read -rp "  Press Enter to continue..." _
        ;;
    esac
  done

else
  # Node B or C — no data load needed, just confirm sync
  printf "  ${C_BOLD}%s${C_RESET} does not run the data load — that happens on Node A\n" "Node${NodeRole}"
  printf "  and replicates here automatically via Galera's synchronous replication.\n"
  echo ""
  printf "  Once Node A completes the data load, verify sync here with:\n"
  echo ""
  printf "    ${C_CYAN}SHOW TABLES IN POS;${C_RESET}              -- confirms structure replicated\n"
  printf "    ${C_CYAN}SELECT COUNT(*) FROM POS.Orderline;${C_RESET}  -- confirms data replicated\n"
  printf "    ${C_CYAN}SHOW STATUS LIKE 'wsrep_cluster_size';${C_RESET} -- confirms all 3 nodes up\n"
  echo ""
  printf "  ${C_DIM}To enter MariaDB: sudo mariadb${C_RESET}\n"
  echo ""

  printf "${C_BOLD}${C_GREEN}"
  printf "  ╔══════════════════════════════════════════════════════════╗\n"
  printf "  ║   Node%s is configured and in the cluster.                ║\n" "$NodeRole"
  printf "  ║   Galera setup complete on this node.                    ║\n"
  printf "  ║   Wait for Node A to load the database.                  ║\n"
  printf "  ╚══════════════════════════════════════════════════════════╝\n"
  printf "${C_RESET}"
  echo ""
  read -rp "  Press Enter to exit..." _
fi
WIZEOF

chmod 755 /usr/local/bin/galera-setup

touch /root/galera-bootstrap-complete
LogStatus "Galera node bootstrap complete"
LogStatus "Run 'sudo galera-setup' to configure and start the cluster"

echo ""
echo "============================================================"
echo "  Node bootstrap complete."
echo "  When watchud exits, run:  sudo galera-setup"
echo "============================================================"
