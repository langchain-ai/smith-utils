#!/usr/bin/env python3
"""
Copy a publicly shared LangSmith trace to your own account.

This script fetches a trace from a public share token and re-ingests it
into your own LangSmith account with proper ID transformations.

Usage:
    python copy_public_trace.py <share_token> --project "My Project"
    
    # Or with environment variables
    export LANGSMITH_API_KEY=your-api-key
    python copy_public_trace.py <share_token> --project "My Project"
    
    # For EU region
    python copy_public_trace.py <share_token> --project "My Project" --region eu

Examples:
    # US region (default)
    python copy_public_trace.py abc123def456 --project "Copied Traces" --api-key ls__xxx
    
    # EU region
    python copy_public_trace.py abc123def456 --project "Copied Traces" --api-key ls__xxx --region eu
"""

import argparse
import json
import os
import sys
from datetime import datetime
from typing import Any, Dict, List, Optional
from uuid import UUID, uuid4

import requests
from langsmith import Client


class PublicTraceDownloader:
    """Downloads a public trace from LangSmith."""
    
    def __init__(self, share_token: str, base_url: str = "https://api.smith.langchain.com"):
        self.share_token = share_token
        self.base_url = base_url.rstrip("/")
        
    def get_root_run(self) -> Dict[str, Any]:
        """Fetch the root run of the shared trace."""
        url = f"{self.base_url}/public/{self.share_token}/run"
        response = requests.get(url)
        response.raise_for_status()
        return response.json()
    
    def get_all_runs(self) -> List[Dict[str, Any]]:
        """Fetch all runs in the shared trace."""
        runs = []
        offset = 0
        limit = 100
        
        while True:
            url = f"{self.base_url}/public/{self.share_token}/runs/query"
            payload = {
                "offset": offset,
                "limit": limit,
            }
            
            response = requests.post(url, json=payload)
            response.raise_for_status()
            data = response.json()
            
            batch = data.get("runs", [])
            if not batch:
                break
                
            runs.extend(batch)
            offset += len(batch)
            
            # Check if we've fetched all runs
            if len(batch) < limit:
                break
        
        return runs
    
    def get_feedbacks(self, run_ids: Optional[List[str]] = None) -> List[Dict[str, Any]]:
        """Fetch feedbacks associated with the shared runs."""
        feedbacks = []
        offset = 0
        limit = 100
        
        while True:
            url = f"{self.base_url}/public/{self.share_token}/feedbacks"
            params = {
                "offset": offset,
                "limit": limit,
            }
            if run_ids:
                params["run"] = run_ids
            
            response = requests.get(url, params=params)
            response.raise_for_status()
            batch = response.json()
            
            if not batch:
                break
                
            feedbacks.extend(batch)
            offset += len(batch)
            
            if len(batch) < limit:
                break
        
        return feedbacks


class TraceTransformer:
    """Transforms run data for re-ingestion with new IDs."""
    
    def __init__(self, target_project: str, preserve_timestamps: bool = True):
        self.target_project = target_project
        self.preserve_timestamps = preserve_timestamps
        self.id_mapping: Dict[str, str] = {}  # old_id -> new_id
        self.dotted_order_mapping: Dict[str, str] = {}  # old_id -> new_dotted_order
        self.new_trace_id: Optional[str] = None
        
    def transform_runs(self, runs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Transform runs with new IDs while maintaining parent-child relationships.
        
        Returns runs sorted in execution order (parents before children).
        """
        # Sort runs by dotted_order to ensure parents come before children
        sorted_runs = sorted(runs, key=lambda r: r.get("dotted_order", ""))
        
        # First pass: generate new IDs for all runs
        for run in sorted_runs:
            old_id = str(run["id"])
            new_id = str(uuid4())
            self.id_mapping[old_id] = new_id
            
            # The first run (root) determines the new trace_id
            if run.get("parent_run_id") is None:
                self.new_trace_id = new_id
        
        # Second pass: transform runs with new IDs
        transformed_runs = []
        for run in sorted_runs:
            transformed = self._transform_single_run(run)
            transformed_runs.append(transformed)
        
        return transformed_runs
    
    def _transform_single_run(self, run: Dict[str, Any]) -> Dict[str, Any]:
        """Transform a single run with new IDs."""
        old_id = str(run["id"])
        new_id = self.id_mapping[old_id]
        
        # Determine new parent_run_id
        old_parent_id = run.get("parent_run_id")
        new_parent_id = None
        if old_parent_id:
            new_parent_id = self.id_mapping.get(str(old_parent_id))
        
        # Build the transformed run
        transformed = {
            "id": new_id,
            "trace_id": self.new_trace_id,
            "parent_run_id": new_parent_id,
            "name": run.get("name"),
            "run_type": run.get("run_type"),
            "start_time": run.get("start_time") if self.preserve_timestamps else datetime.utcnow().isoformat(),
            "end_time": run.get("end_time") if self.preserve_timestamps else None,
            "inputs": run.get("inputs", {}),
            "outputs": run.get("outputs", {}),
            "extra": run.get("extra", {}),
            "error": run.get("error"),
            "serialized": run.get("serialized"),
            "events": run.get("events", []),
            "tags": run.get("tags", []),
            "session_name": self.target_project,
        }
        
        # Add metadata about the source
        if "extra" not in transformed or transformed["extra"] is None:
            transformed["extra"] = {}
        if "metadata" not in transformed["extra"]:
            transformed["extra"]["metadata"] = {}
        
        transformed["extra"]["metadata"]["copied_from_shared_trace"] = True
        transformed["extra"]["metadata"]["original_run_id"] = old_id
        
        # Include token counts if present
        if "total_tokens" in run:
            transformed["total_tokens"] = run["total_tokens"]
        if "prompt_tokens" in run:
            transformed["prompt_tokens"] = run["prompt_tokens"]
        if "completion_tokens" in run:
            transformed["completion_tokens"] = run["completion_tokens"]
        if "first_token_time" in run:
            transformed["first_token_time"] = run["first_token_time"]
        
        # Calculate dotted_order for the new run
        # Format: {timestamp}Z{run_id_hex} for each part
        # Timestamp format: %Y%m%dT%H%M%S%fZ (no dots, colons, or hyphens)
        # Example: 20230505T051324571809Zdc74395ec01849ce970d270dcc3d01d8
        
        start_time = run.get("start_time")
        if isinstance(start_time, str):
            start_time_dt = datetime.fromisoformat(start_time.replace('Z', '+00:00'))
        else:
            start_time_dt = start_time or datetime.utcnow()
        
        # Format timestamp without separators
        formatted_timestamp = start_time_dt.strftime("%Y%m%dT%H%M%S%f") + "Z"
        run_id_hex = new_id.replace("-", "")  # Remove hyphens from UUID
        current_part = f"{formatted_timestamp}{run_id_hex}"
        
        if new_parent_id:
            # For child runs, prepend parent's dotted order
            old_parent_id = str(run.get("parent_run_id"))
            parent_dotted_order = self.dotted_order_mapping.get(old_parent_id)
            if parent_dotted_order:
                transformed["dotted_order"] = f"{parent_dotted_order}.{current_part}"
            else:
                # Fallback: just use current part (shouldn't happen if we process in order)
                transformed["dotted_order"] = current_part
        else:
            # Root run - single part only
            transformed["dotted_order"] = current_part
        
        # Store the dotted order for this run so children can use it
        self.dotted_order_mapping[old_id] = transformed["dotted_order"]
        
        return transformed


class TraceUploader:
    """Uploads transformed runs to LangSmith."""
    
    def __init__(self, client: Client):
        self.client = client
        
    def upload_runs(self, runs: List[Dict[str, Any]], project_name: str) -> None:
        """
        Upload runs to LangSmith.
        
        The LangSmith client handles batching and proper ingestion.
        """
        print(f"Uploading {len(runs)} runs to project '{project_name}'...")
        
        # Create runs using the client's create_run method
        # We need to do this in order (parents before children)
        for i, run in enumerate(runs, 1):
            try:
                # The Client.create_run method expects specific fields
                self.client.create_run(
                    name=run["name"],
                    run_type=run["run_type"],
                    inputs=run.get("inputs", {}),
                    outputs=run.get("outputs"),
                    project_name=project_name,
                    start_time=run.get("start_time"),
                    end_time=run.get("end_time"),
                    error=run.get("error"),
                    extra=run.get("extra"),
                    serialized=run.get("serialized"),
                    events=run.get("events"),
                    tags=run.get("tags"),
                    trace_id=run["trace_id"],
                    dotted_order=run.get("dotted_order"),
                    id=run["id"],
                    parent_run_id=run.get("parent_run_id"),
                )
                
                if i % 10 == 0:
                    print(f"  Uploaded {i}/{len(runs)} runs...")
                    
            except Exception as e:
                print(f"Error uploading run {run['id']}: {e}", file=sys.stderr)
                raise
        
        print(f"✓ Successfully uploaded all {len(runs)} runs!")


def main():
    parser = argparse.ArgumentParser(
        description="Copy a publicly shared LangSmith trace to your account",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    
    parser.add_argument(
        "share_token",
        help="The share token from the public trace URL"
    )
    
    parser.add_argument(
        "--project",
        "-p",
        required=True,
        help="Target project name in your LangSmith account"
    )
    
    parser.add_argument(
        "--api-key",
        help="LangSmith API key (or set LANGSMITH_API_KEY env var)"
    )
    
    parser.add_argument(
        "--endpoint",
        help="LangSmith API endpoint (overrides --region if specified)"
    )
    
    parser.add_argument(
        "--region",
        choices=['eu', 'us'],
        help="API region: 'eu' for Europe (https://eu.api.smith.langchain.com) or 'us' for US (https://api.smith.langchain.com). Default is 'us'."
    )
    
    parser.add_argument(
        "--update-timestamps",
        action="store_true",
        help="Update timestamps to current time instead of preserving originals"
    )
    
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Download and transform but don't upload"
    )
    
    args = parser.parse_args()
    
    # Determine the API endpoint
    if args.endpoint:
        # Explicit endpoint takes precedence
        endpoint = args.endpoint
    elif args.region == 'eu':
        endpoint = "https://eu.api.smith.langchain.com"
    else:
        # Default to US endpoint
        endpoint = os.getenv("LANGCHAIN_ENDPOINT", "https://api.smith.langchain.com")
    
    # Get API key from args or environment
    api_key = args.api_key or os.getenv("LANGSMITH_API_KEY")
    if not api_key:
        print("Error: API key required. Set LANGSMITH_API_KEY or use --api-key", file=sys.stderr)
        sys.exit(1)
    
    try:
        # Step 1: Download the public trace
        print(f"Fetching public trace with token: {args.share_token}")
        print(f"Using endpoint: {endpoint}")
        downloader = PublicTraceDownloader(args.share_token, endpoint)
        
        print("  Downloading root run...")
        root_run = downloader.get_root_run()
        print(f"  ✓ Root run: {root_run.get('name')} (ID: {root_run.get('id')})")
        
        print("  Downloading all runs in trace...")
        all_runs = downloader.get_all_runs()
        print(f"  ✓ Found {len(all_runs)} runs")
        
        # Step 2: Transform the runs
        print(f"\nTransforming runs for project '{args.project}'...")
        transformer = TraceTransformer(
            target_project=args.project,
            preserve_timestamps=not args.update_timestamps
        )
        transformed_runs = transformer.transform_runs(all_runs)
        print(f"  ✓ Transformed {len(transformed_runs)} runs")
        print(f"  New trace ID: {transformer.new_trace_id}")
        
        if args.dry_run:
            print("\n[DRY RUN] Would upload the following:")
            print(f"  Project: {args.project}")
            print(f"  Runs: {len(transformed_runs)}")
            print(f"  Trace ID: {transformer.new_trace_id}")
            print("\nSample transformed run:")
            print(json.dumps(transformed_runs[0], indent=2, default=str))
            return
        
        # Step 3: Upload to LangSmith
        print(f"\nUploading to LangSmith...")
        client = Client(api_key=api_key, api_url=endpoint)
        uploader = TraceUploader(client)
        uploader.upload_runs(transformed_runs, args.project)
        
        print(f"\n✓ Successfully copied trace to project '{args.project}'!")
        print(f"  Original runs: {len(all_runs)}")
        print(f"  New trace ID: {transformer.new_trace_id}")
        
    except requests.HTTPError as e:
        print(f"\nHTTP Error: {e}", file=sys.stderr)
        print(f"Response: {e.response.text}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()

