#!/usr/bin/env python3
"""
Create Railway project and connect GitHub repo.
Usage: python3 create-railway.py YOUR_TOKEN
"""
import sys, json, subprocess, os

RAILWAY_GQL = "https://backboard.railway.com/graphql/v2"

def gql(token, query, variables=None):
    body = {"query": query}
    if variables:
        body["variables"] = variables
    env = os.environ.copy()
    env["HTTPS_PROXY"] = ""
    env["HTTP_PROXY"] = ""
    result = subprocess.run(
        ["curl.exe", "-s", "-X", "POST", RAILWAY_GQL,
         "-H", f"Authorization: Bearer {token}",
         "-H", "Content-Type: application/json",
         "-d", json.dumps(body)],
        capture_output=True, text=True, env=env
    )
    data = json.loads(result.stdout)
    if data.get("errors"):
        print(f"ERROR: {data['errors']}")
        sys.exit(1)
    return data["data"]

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 create-railway-project.py RAILWAY_TOKEN")
        print("")
        print("Create token at: https://railway.com/account/tokens")
        sys.exit(1)

    token = sys.argv[1]
    PROJECT_NAME = "ccx-miner"
    REPO_URL = "https://github.com/frozen-river324/CryNightR"
    REPO_BRANCH = "main"

    # 1. Create project
    print("1. Creating project...")
    r = gql(token, "mutation { projectCreate(name: $name) { project { id name } } }",
            {"name": PROJECT_NAME})
    project = r["projectCreate"]["project"]
    project_id = project["id"]
    print(f"   Project: {project['name']} (ID: {project_id})")

    # 2. Get environment
    print("2. Getting environment...")
    r = gql(token,
            "query { project(id: $pid) { environments { edges { node { id name } } } } }",
            {"pid": project_id})
    env = r["project"]["environments"]["edges"][0]["node"]
    env_id = env["id"]
    print(f"   Environment: {env['name']} (ID: {env_id})")

    # 3. Create service from GitHub
    print("3. Creating service from GitHub...")
    r = gql(token,
            "mutation { provisionGitHubPlugin(input: { projectId: $pid, envId: $eid, repoUrl: $repo, branch: $branch }) { service { id name } } }",
            {"pid": project_id, "eid": env_id, "repo": REPO_URL, "branch": REPO_BRANCH})
    service = r["provisionGitHubPlugin"]["service"]
    service_id = service["id"]
    print(f"   Service: {service['name']} (ID: {service_id})")

    # 4. Set environment variables
    print("4. Setting environment variables...")
    vars_set = {
        "WALLET": "ccx7BaYihWz3LkJmDT1sx76cafd9JKVyBikc55H8jqiAWe8QVzjpxi1PGBRGjc78DU6vhuR1yXMVFDwmWM1Mj1zs46mdtNSNMy",
        "POOL_URL": "mine.conceal.network",
        "POOL_PORT": "16055",
        "ALGO": "cn/ccx",
        "TLS": "false",
        "POOL_PASS": "x",
        "DONATE": "1",
        "PORT": "8080",
    }
    for name, value in vars_set.items():
        gql(token,
            "mutation { variableUpsert(input: { projectId: $pid, environmentId: $eid, serviceId: $sid, name: $n, value: $v }) { id } }",
            {"pid": project_id, "eid": env_id, "sid": service_id, "n": name, "v": value})
        print(f"   Set {name}={value}")

    # 5. Set instance type (minimal for small servers)
    print("5. Setting instance config...")
    gql(token,
        "mutation { serviceUpdateInput(input: { serviceId: $sid, instanceId: $iid, minInstances: 1, maxInstances: 1, verticalAutoScaling: false, horizontalAutoScaling: false, size: 'shared-basic' }) { success } }",
        {"sid": service_id, "iid": "0"})

    print(f"\n============================================")
    print(f" Done!")
    print(f" Project: {project['name']}")
    print(f" URL: https://railway.com/project/{project_id}")
    print(f" Service: {service['name']}")
    print(f"============================================")

if __name__ == "__main__":
    main()