#!/usr/bin/env python3
"""
Check and list LangGraph deployments using LangSmith API key.

This script connects to the LangSmith API to retrieve and display a list of
LangGraph deployments. It requires the LANGSMITH_API_KEY environment variable
to be set (via .env file or environment).

Usage:
    python check_deployments_api_key.py
"""
import os
import requests
from dotenv import load_dotenv
 
load_dotenv()
 
# LangSmith API base URL
API_BASE_URL = "https://gtm.smith.langchain.dev/api-host/v2"
API_KEY = os.environ["LANGSMITH_API_KEY"]  # <-- set this in your environment
 
def list_deployments(name_contains=None):
    """List LangGraph deployments via LangSmith API key."""
    headers = {
        "X-Api-Key": API_KEY,
        "Content-Type": "application/json",
    }
 
    params = {}
    if name_contains:
        params["name_contains"] = name_contains
 
    resp = requests.get(f"{API_BASE_URL}/deployments", headers=headers, params=params)
 
    if resp.status_code == 200:
        return resp.json()
    else:
        raise RuntimeError(f"❌ Failed: {resp.status_code} - {resp.text}")
 
if __name__ == "__main__":
    data = list_deployments()  # or list_deployments("text2sql-agent")
    for d in data.get("resources", []):
        print(f"{d.get('id'):<20} {d.get('name')}")
