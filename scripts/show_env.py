"""
Display environment information including LangChain, LangSmith, and Python runtime versions.

This script collects and prints version information for:
- LangChain Core
- LangChain
- LangSmith SDK
- Python runtime and platform details
"""
import platform
import sys
from importlib.metadata import version

env_data = {
    "langchain_core_version": version("langchain-core"),
    "langchain_version": version("langchain"),
    "library": "langsmith",
    "platform": platform.platform(),
    "py_implementation": platform.python_implementation(),
    "runtime": "python",
    "runtime_version": platform.python_version(),
    "sdk": "langsmith-py",
    "sdk_version": version("langsmith")
}

print(env_data)
