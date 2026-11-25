from mcp.server.fastmcp import FastMCP

import smh_core

mcp = FastMCP("smh")


@mcp.tool()
def search_sims_mods(query: str) -> list[dict]:
    """Search CurseForge for Sims 4 mods. Returns up to five matches with projectId, creator, page link and whether it can be installed."""
    return smh_core.search_sims_mods(query)


@mcp.tool()
def queue_install(project_id: int, file_id: int, requested_by: str) -> dict:
    """Ask the child's PC to install a mod, using projectId and latestFileId from a search result. Returns queued true with an id, or queued false with a plain reason."""
    return smh_core.queue_install(project_id, file_id, requested_by)


@mcp.tool()
def queue_uninstall(project_id: int, requested_by: str) -> dict:
    """Ask the child's PC to remove an installed mod by projectId. Returns queued true with an id, or queued false with a plain reason."""
    return smh_core.queue_uninstall(project_id, requested_by)


@mcp.tool()
def list_installs() -> list[dict]:
    """List the mods the child's PC has installed, blocked or removed, with projectId, name, status and reason."""
    return smh_core.list_installs()


if __name__ == "__main__":
    mcp.run()
