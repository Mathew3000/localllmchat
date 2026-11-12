package com.local.local_llm_chat

import androidx.core.content.FileProvider

/** Own subclass so it never clashes with FileProviders declared by plugins. */
class UpdateFileProvider : FileProvider()
