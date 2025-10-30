plugins {
  java
}

java {
  toolchain { languageVersion.set(org.gradle.jvm.toolchain.JavaLanguageVersion.of(17)) }
}

repositories {
  mavenCentral()
  maven {
    url = uri("https://repository.jboss.org/nexus/repository/snapshots/")
    mavenContent { snapshotsOnly() }
  }
}

dependencies {
  testImplementation("org.hibernate.orm:hibernate-core:" + property("hibernateVersion"))
  testImplementation("com.mysql:mysql-connector-j:" + property("mysqlJdbcVersion"))
  testImplementation("org.slf4j:slf4j-simple:2.0.13")
  testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
}

tasks.test {
  useJUnitPlatform()
  // Emit JUnit XML reports under build/test-results/test
  reports.junitXml.required.set(true)
  reports.html.required.set(true)
  // Let the test task complete so we can build a summary and decide failure ourselves.
  ignoreFailures = true

  // Allowlist of known failures: if present, we don’t fail the build on them
  doLast {
    val resultsDir = file("build/test-results/test").listFiles()?.toList() ?: emptyList()
    val failed = resultsDir.flatMap { f ->
      if (f.name.startsWith("TEST-") && f.extension == "xml") {
        val text = f.readText()
        Regex("<testcase[\\s\\S]*?</testcase>").findAll(text).mapNotNull { tc ->
          if (tc.value.contains("<failure")) {
            val cls = Regex("classname=\"([^\"]+)\"").find(tc.value)?.groupValues?.getOrNull(1)
            val name = Regex("name=\"([^\"]+)\"").find(tc.value)?.groupValues?.getOrNull(1)
            if (cls != null && name != null) "$cls#$name" else null
          } else null
        }.toList()
      } else emptyList()
    }.toSet()

    val allow = if (file("allowlist.txt").exists()) file("allowlist.txt").readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("#") }.toSet() else emptySet()
    val unexpected = failed - allow
    val summary = file("build/summary.txt")
    summary.writeText("FAILED=" + failed.size + "\nUNEXPECTED=" + unexpected.size + "\n")
    if (unexpected.isNotEmpty()) {
      summary.appendText("Unexpected failures:\n" + unexpected.joinToString("\n") + "\n")
      throw GradleException("Unexpected test failures: ${unexpected.size}")
    }
  }
}
