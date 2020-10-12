<?php

namespace DDTrace\Integrations\WordPress;

use DDTrace\Integrations\Integration;
use DDTrace\Integrations\WordPress\V4\WordPressIntegrationLoader;

class WordPressIntegration extends Integration
{
    const NAME = 'wordpress';

    /**
     * @var self
     */
    private static $instance;

    /**
     * @return self
     */
    public static function getInstance()
    {
        if (null === self::$instance) {
            self::$instance = new self();
        }
        return self::$instance;
    }

    /**
     * @return string The integration name.
     */
    public function getName()
    {
        return self::NAME;
    }

    /**
     * {@inheritdoc}
     */
    public function requiresExplicitTraceAnalyticsEnabling()
    {
        return false;
    }

    /**
     * {@inheritdoc}
     */
    public function init()
    {
        if (!self::shouldLoad(self::NAME)) {
            return self::NOT_AVAILABLE;
        }

        $integration = self::getInstance();

        // This call happens right after WP registers an autoloader for the first time
        \DDTrace\trace_method('Requests', 'set_certificate_path', function () use ($integration) {
            $loader = new WordPressIntegrationLoader();
            $loader->load($integration);

            return false; // Drop this span to reduce noise
        });

        return self::LOADED;
    }
}
