# MVP infrastructure

## Cognito User Pool — T-1.4

Traceability: [T-1.4](../specs/tasks.md) → R-AUTH-1, R-TEN-3 → [ADR-005](../../docs/adr/ADR-005-api-layer.md); tenant-claim use follows [MVP design §2.5](../specs/design.md).

Status: T-1.4 complete, recorded 2026-10-25. The authoritative task status is in `specs/tasks.md`.

## Deployed Cognito resource (2026-10-25)

| Setting | Value |
|---|---|
| AWS account / profile | `129896631584` / `sensor-monitoring` |
| Region | `us-east-2` |
| User Pool | `iot-sensor-mvp-users` / `us-east-2_Jon5KZgmo` |
| ARN | `arn:aws:cognito-idp:us-east-2:129896631584:userpool/us-east-2_Jon5KZgmo` |
| Feature plan | Essentials |
| Deletion protection | Active |
| Custom attribute | Immutable string `custom:tenant_id`, length 1–2048 |
| Tags | `Project=sensor-monitoring-platform`, `Increment=mvp`, `Task=T-1.4` |

`custom:tenant_id` is intentionally immutable so a user cannot move to another tenant after creation. Cognito does not permit custom attributes to be required. Assign the value when an administrator creates each user. It will be emitted as a signed ID-token claim when a future app client grants it read access; FastAPI validation and tenant scoping belong to T-3.2 and T-3.3.

This task does not create a user, app client, hosted-login configuration, or MFA policy. T-4.1 owns the React login integration and T-3.2 owns JWT validation. Use [cognito-user-pool.example.json](cognito-user-pool.example.json) as the reviewed, credential-free request template for a separate environment; before submitting it, inspect the target account for an existing pool with the same purpose and do not duplicate a live deployment.

## RDS PostgreSQL — T-1.3

Traceability: [T-1.3](../specs/tasks.md) → R-STO-1 → [ADR-008](../../docs/adr/ADR-008-native-postgresql-storage.md); networking follows [MVP design §2.8](../specs/design.md).

Provision PostgreSQL 15 on `db.t4g.micro`, Single-AZ. Native partitioning is built into PostgreSQL; there is no extension to install. Schema/partition creation is T-2.4, the device registry is T-2.5, and manual purge documentation is T-2.6. This procedure does not create application tables or purge jobs.

Status: T-1.3 complete, recorded 2026-10-12. RDS reported `available` with no pending modifications, and live TLS/SQL verification passed. The authoritative task status is in `specs/tasks.md`.

## Deployed resources (2026-10-11)

| Setting | Value |
|---|---|
| AWS account / profile | `129896631584` / `sensor-monitoring` |
| Region | `us-east-2` |
| Instance / database | `iot-sensor-mvp-postgres` / `iot_platform` |
| Engine / class | PostgreSQL `15.19` / `db.t4g.micro`, Single-AZ |
| Storage | Encrypted 20 GiB gp3 |
| Endpoint | `iot-sensor-mvp-postgres.cl26wmy4ay8s.us-east-2.rds.amazonaws.com:5432` |
| VPC | `vpc-0e865c7d78eca38eb` |
| Subnet group | `iot-sensor-mvp-postgres` |
| Subnets | `subnet-05daa4b0cc0a9e351`, `subnet-043be30d62b653a5b`, `subnet-0268e8f61b182902d` |
| Security group | `sg-00305a39ffce388b9`; TCP 5432 from `186.71.111.108/32` only |
| Parameter group | `default.postgres15`; `rds.force_ssl=1` verified |
| Backups / deletion protection | One-day automated backups / enabled |
| Credentials | RDS-managed Secrets Manager secret; use `MasterUserSecret.SecretArn` from instance metadata |

The operator IP rule must be reviewed when the workstation's public IP changes. Application access is not granted yet; Lambda/Fargate tasks must add their intended security-group sources when deployed. Public accessibility alone does not permit internet-wide connections.

Recreate the named subnet/security groups in the selected account before using the request template. The recorded IDs identify this deployment and are not portable to another account/VPC. SQL verification used hostname-validated TLS (`sslmode=verify-full`) and runtime secret resolution; `iot_platform` reported PostgreSQL 15.19, native partitioning available, and only the built-in `plpgsql` extension. Application tables and purge schedules remain for their owning tasks.

## 1. Establish the deployment target

Use AWS CLI v2 in an authenticated local session or AWS CloudShell in the intended account. Configure the account/profile and region before running any mutations; never put AWS credentials or database passwords in this repository.

```bash
export AWS_REGION='<target-region>'
export AWS_PAGER=''
# For a local named profile only; omit in CloudShell:
export AWS_PROFILE='<profile-name>'
aws sts get-caller-identity
```

Check that the returned account is the intended project account. Inspect existing RDS instances to avoid duplicating a database or modifying an unrelated resource:

```bash
aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass}'

aws rds describe-orderable-db-instance-options --region "$AWS_REGION" \
  --engine postgres --db-instance-class db.t4g.micro \
  --query "OrderableDBInstanceOptions[?starts_with(EngineVersion, '15.') && StorageType == 'gp3'].{Version:EngineVersion,Storage:StorageType,MinimumGiB:MinStorageSize}"
```

Choose an available PostgreSQL **15.x** minor version from the response. Do not substitute a different major version or instance class if this combination is unavailable.

## 2. Select and inspect networking

Use the project's VPC and a DB subnet group spanning at least two Availability Zones, even though the instance itself is Single-AZ. The MVP design uses public subnets: inspect their route tables for internet-gateway routing, and ensure the VPC has DNS support and DNS hostnames enabled.

```bash
aws rds describe-db-subnet-groups --region "$AWS_REGION" \
  --query 'DBSubnetGroups[].{Name:DBSubnetGroupName,Vpc:VpcId,Status:SubnetGroupStatus,Subnets:Subnets}'

aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters 'Name=vpc-id,Values=<project-vpc-id>' \
  --query 'SecurityGroups[].{Id:GroupId,Name:GroupName,Ingress:IpPermissions}'
```

The chosen security group must be in the same VPC and allow TCP 5432 only from the operator's specific source IP/CIDR or the intended application security groups. Do not use internet-wide ingress (`0.0.0.0/0` or `::/0`). `PubliclyAccessible` does not replace these restrictions. If the project has no suitable subnet/security groups, create and inspect them before creating the instance; their IDs and allowed sources depend on the selected AWS environment.

## 3. Prepare and submit the instance request

Copy `rds-instance.example.json` to a temporary file outside the repository. Replace all `REPLACE_WITH_...` values with the inspected PostgreSQL minor version, DB subnet group, and restricted security group ID. Review the identifier for collisions.

The request uses encrypted 20 GiB gp3 storage, the initial storage size recorded in the previous storage decision. One-day automated backups and deletion protection are provisioning safeguards; backup retention does not delete live sensor rows. The account Free Plan rejected the original seven-day setting; one day was accepted. RDS manages the master password in Secrets Manager, avoiding passwords in CLI arguments or files. Secrets Manager has separate service charges. Do not print or commit the secret value.

```bash
# Run from the repository root.
cp iot-sensor-mvp/infrastructure/rds-instance.example.json /tmp/iot-sensor-mvp-rds.json
# Edit /tmp/iot-sensor-mvp-rds.json to replace the deployment placeholders.
python3 - <<'PY'
import json
from pathlib import Path
request = json.loads(Path('/tmp/iot-sensor-mvp-rds.json').read_text())
assert 'REPLACE_WITH_' not in json.dumps(request), 'Fill in deployment placeholders first'
assert request['EngineVersion'].startswith('15.')
assert request['DBInstanceClass'] == 'db.t4g.micro'
assert request['MultiAZ'] is False
assert request['ManageMasterUserPassword'] is True
assert 'MasterUserPassword' not in request
print('Local request checks passed; AWS still validates account-specific inputs.')
PY
```

After the local checks pass, submit the reviewed request in the intended account:

```bash
aws rds create-db-instance --region "$AWS_REGION" \
  --cli-input-json file:///tmp/iot-sensor-mvp-rds.json \
  --query 'DBInstance.{Id:DBInstanceIdentifier,Status:DBInstanceStatus}'
```

This command creates a billable resource. Do not repeat creation if the response is interrupted or uncertain; inspect the same instance identifier first. If it already exists, verify its settings instead of changing or deleting it automatically.

## 4. Verify deployment

Instance creation takes several minutes. Inspect until the status is `available`:

```bash
aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier iot-sensor-mvp-postgres \
  --query 'DBInstances[0].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,Database:DBName,StorageGiB:AllocatedStorage,StorageType:StorageType,Encrypted:StorageEncrypted,Public:PubliclyAccessible,SubnetGroup:DBSubnetGroup.DBSubnetGroupName,SecurityGroups:VpcSecurityGroups,Endpoint:Endpoint.Address,Port:Endpoint.Port,SecretStatus:MasterUserSecret.SecretStatus,BackupDays:BackupRetentionPeriod,DeletionProtection:DeletionProtection,Pending:PendingModifiedValues}'
```

Verify the selected version/class, Single-AZ, intended subnet/security groups, storage settings, active managed secret, and database name. Use the installed `aws-secrets-manager` skill and its `asm-exec` helper to resolve the password at runtime. Never fetch the secret into a tool response. From a permitted network source, connect with `psql` using the RDS CA bundle from the [AWS certificate documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html). Set `T13_SECRET_ARN` from the instance metadata and `T13_ENDPOINT` from the verified endpoint. The dynamic reference is resolved only inside the helper/child process:

```bash
AWS_PROFILE=sensor-monitoring AWS_REGION=us-east-2 \
  PGPASSWORD="{{resolve:secretsmanager:${T13_SECRET_ARN}:SecretString:password}}" \
  python3 /home/byron/.codex/skills/aws-secrets-manager/references/asm-exec -- \
  psql "host=${T13_ENDPOINT} port=5432 dbname=iot_platform user=postgres sslmode=verify-full sslrootcert=<local-rds-ca-bundle-path>"
```

Run these read-only checks:

```sql
SELECT current_database(), current_setting('server_version');
SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();
SELECT to_regprocedure('pg_catalog.pg_partition_tree(regclass)') IS NOT NULL
    AS native_partitioning_available;
SELECT extname FROM pg_extension ORDER BY extname;
```

Expect `iot_platform`, PostgreSQL 15.x, TLS enabled, and native partitioning available. No TimescaleDB or automated purge extension is required or installed by this procedure. No application schema is created as part of verification.

Only after live checks pass, record the account/region, instance identifier, endpoint, version, and verification result in the T-1.3 note in `specs/tasks.md` (no credentials), set T-1.3 to `done`, update progress counts, and note that T-2.4/T-2.5 are unblocked. A prepared JSON request or an instance still being created does not complete T-1.3.

## AWS references

- [CreateDBInstance CLI options](https://docs.aws.amazon.com/cli/latest/reference/rds/create-db-instance.html)
- [RDS networking and subnet requirements](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_VPC.WorkingWithRDSInstanceinaVPC.html)
- [RDS-managed credentials in Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
